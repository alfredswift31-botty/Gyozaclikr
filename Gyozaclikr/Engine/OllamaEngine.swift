import Foundation

// Ollama on this Mac (or a host the user named): the labelled second engine
// for image questions Apple's 3B model answers badly, and for text when the
// user asks with /local. Requests are built and responses parsed by pure
// types so the wire format is tested without a server.

/// Builds the HTTP requests. Pure: host + fields in, `URLRequest` out.
nonisolated enum OllamaRequest {
    static let defaultHost = "http://127.0.0.1:11434"
    /// How long Ollama keeps the model loaded after an answer.
    static let keepAlive = "10m"

    /// The host as a base URL string: a scheme added when missing, trailing
    /// slashes removed, the default when empty.
    static func normalisedHost(_ raw: String?) -> String {
        var host = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { host = defaultHost }
        if !host.lowercased().hasPrefix("http://"), !host.lowercased().hasPrefix("https://") {
            host = "http://" + host
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    /// Whether answers leave this Mac (docs/DESIGN.md: "leaves this Mac").
    static func isLocal(_ host: String) -> Bool {
        guard let name = URL(string: normalisedHost(host))?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0"].contains(name)
    }

    static func tags(host: String, timeout: TimeInterval = 2) -> URLRequest? {
        guard let url = URL(string: normalisedHost(host) + "/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return request
    }

    /// A streaming `/api/chat` request. `imagePNG` goes on the user message as
    /// one base64 image; the `images` key is absent for text.
    static func chat(host: String, model: String, system: String, user: String, imagePNG: Data? = nil,
                     keepAlive: String = keepAlive, timeout: TimeInterval = 180) -> URLRequest? {
        guard let url = URL(string: normalisedHost(host) + "/api/chat") else { return nil }
        let body = ChatBody(
            model: model,
            stream: true,
            keep_alive: keepAlive,
            options: ChatBody.Options(temperature: 0.2),
            messages: [
                ChatBody.Message(role: "system", content: system, images: nil),
                ChatBody.Message(role: "user", content: user, images: imagePNG.map { [$0.base64EncodedString()] })
            ]
        )
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// The JSON body of `/api/chat`. Field names are Ollama's.
    struct ChatBody: Encodable {
        struct Options: Encodable { var temperature: Double }
        struct Message: Encodable {
            var role: String
            var content: String
            /// Omitted when nil, so a text request carries no `images` key.
            var images: [String]?
        }
        var model: String
        var stream: Bool
        var keep_alive: String
        var options: Options
        var messages: [Message]
    }
}

/// One line of the NDJSON stream from `/api/chat`.
nonisolated struct OllamaChunk: Hashable, Sendable {
    var content: String
    var done: Bool
    /// Ollama's `error` field, when a line carries one.
    var error: String?
}

/// Parses the streamed NDJSON from any chunking of the bytes: a line is
/// decoded only once its newline has arrived, so a split mid-line or mid
/// UTF-8 sequence just waits for the rest.
nonisolated struct OllamaStreamParser: Sendable {
    private var buffer = Data()

    init() {}

    mutating func feed(_ data: Data) -> [OllamaChunk] {
        buffer.append(data)
        var chunks: [OllamaChunk] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let chunk = Self.parse(line: line) { chunks.append(chunk) }
        }
        return chunks
    }

    /// The last line, when the stream ended without a newline.
    mutating func finish() -> [OllamaChunk] {
        defer { buffer.removeAll() }
        guard let chunk = Self.parse(line: buffer) else { return [] }
        return [chunk]
    }

    static func parse(line: Data) -> OllamaChunk? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let error = object["error"] as? String {
            return OllamaChunk(content: "", done: true, error: error)
        }
        let message = object["message"] as? [String: Any]
        let content = (message?["content"] as? String) ?? ""
        let done = (object["done"] as? Bool) ?? false
        return OllamaChunk(content: content, done: done, error: nil)
    }
}

/// Picks models from `/api/tags`.
nonisolated enum OllamaModels {
    static let fallbackVisionModel = "qwen3-vl"

    /// Tag names from the `/api/tags` body, in Ollama's order.
    static func names(fromTagsJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    static func isVision(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        return lower.contains("vl") || lower.contains("vision")
    }

    /// The first tag that looks like a vision model, else the usual name.
    static func visionModel(from tags: [String]) -> String {
        tags.first(where: isVision) ?? fallbackVisionModel
    }

    /// The first tag that is not a vision model, else the vision model (it reads text too).
    static func textModel(from tags: [String]) -> String {
        tags.first { !isVision($0) } ?? visionModel(from: tags)
    }
}

/// The Ollama engine. Text and images; no structured output, no tools.
nonisolated struct OllamaEngine: LanguageEngine {
    let kind: EngineKind = .ollama
    let capabilities: Set<EngineCapability> = [.text, .image]

    /// Settings are read per call, so a host change in Settings applies at once.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var host: String { OllamaRequest.normalisedHost(defaults.string(forKey: SettingsKey.ollamaHost)) }

    func status() async -> EngineStatus {
        do {
            _ = try await tags()
            return .ready
        } catch {
            return .unavailable(Self.notRunning(host))
        }
    }

    /// Ollama loads on first request; the box shows elapsed seconds instead.
    func prewarm() async {}

    func transform(prompt: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        let user = prompt + "\n\n" + Prompts.wrap(selection.text ?? "")
        return chat(system: Prompts.instructions, user: user, image: nil, kind: .text, vision: false)
    }

    /// No guided generation here: the list is asked for in words and shown
    /// without a verification claim (kept and dropped stay 0).
    func extract(prompt: String, selection: Selection, asCSV: Bool) -> AsyncStream<AnswerEvent> {
        let format = asCSV
            ? "Answer with CSV lines only: one row per line, cells separated by commas, a header row first."
            : "Answer with a bulleted list only, one item per line, each item taken from the text."
        let user = prompt + "\n" + format + "\n\n" + Prompts.wrap(selection.text ?? "")
        return chat(system: Prompts.instructions, user: user, image: nil, kind: asCSV ? .csv : .extraction, vision: false)
    }

    func describeImage(question: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        guard let payload = selection.image else {
            return Self.single(.failed(.other("There is no image in the selection.")))
        }
        let user = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Describe this image." : question
        let png = ImageScaling.scaledPNG(from: payload)
        return chat(system: Prompts.describeInstructions, user: user, image: png, kind: .description, vision: true)
    }

    func agent(request: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        Self.single(.failed(.other("Tools run on Apple's model.")))
    }

    // MARK: Wire

    static func notRunning(_ host: String) -> String { "Ollama isn't running at \(host)." }

    /// The model list, or a thrown transport error. 2 s: the box must not wait on a dead host.
    func tags() async throws -> [String] {
        guard let request = OllamaRequest.tags(host: host) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return OllamaModels.names(fromTagsJSON: data)
    }

    /// The configured model, else one picked from the server's tags.
    func model(vision: Bool) async -> String {
        let key = vision ? SettingsKey.ollamaVisionModel : SettingsKey.ollamaTextModel
        if let chosen = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            return chosen
        }
        let names = (try? await tags()) ?? []
        return vision ? OllamaModels.visionModel(from: names) : OllamaModels.textModel(from: names)
    }

    private func chat(system: String, user: String, image: Data?, kind: Answer.Kind, vision: Bool) -> AsyncStream<AnswerEvent> {
        let host = host
        return AsyncStream { continuation in
            let task = Task {
                await self.run(host: host, system: system, user: user, image: image, kind: kind, vision: vision, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(host: String, system: String, user: String, image: Data?, kind: Answer.Kind, vision: Bool,
                     continuation: AsyncStream<AnswerEvent>.Continuation) async {
        continuation.yield(.status("Asking Ollama…"))
        let model = await model(vision: vision)
        guard let request = OllamaRequest.chat(host: host, model: model, system: system, user: user, imagePNG: image) else {
            continuation.yield(.failed(.offline("The Ollama host \(host) is not a valid address.")))
            return
        }
        var text = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            var parser = OllamaStreamParser()
            var line = Data()
            var finished = false
            for try await byte in bytes {
                line.append(byte)
                guard byte == 0x0A else { continue }
                let chunks = parser.feed(line)
                line.removeAll(keepingCapacity: true)
                if let stop = try Self.handle(chunks, text: &text, continuation: continuation) {
                    finished = stop
                    if finished { break }
                }
            }
            if !finished {
                _ = try Self.handle(parser.feed(line) + parser.finish(), text: &text, continuation: continuation)
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), text.isEmpty {
                continuation.yield(.failed(.offline("Ollama answered \(http.statusCode) for model \(model).")))
                return
            }
            continuation.yield(.done(Answer(text: text, kind: kind, engine: .ollama)))
        } catch let failure as EngineFailure {
            continuation.yield(.failed(failure))
        } catch {
            continuation.yield(.failed(Self.failure(for: error, host: host)))
        }
    }

    /// Emits the chunks; returns true once Ollama said `done`, throws the failure a chunk carries.
    private static func handle(_ chunks: [OllamaChunk], text: inout String, continuation: AsyncStream<AnswerEvent>.Continuation) throws -> Bool? {
        guard !chunks.isEmpty else { return nil }
        for chunk in chunks {
            if let error = chunk.error { throw EngineFailure.offline("Ollama: \(error)") }
            if !chunk.content.isEmpty {
                text += chunk.content
                continuation.yield(.token(chunk.content))
            }
            if chunk.done { return true }
        }
        return false
    }

    static func failure(for error: Error, host: String) -> EngineFailure {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                return .offline(notRunning(host))
            default: return .offline("Ollama: \(urlError.localizedDescription)")
            }
        }
        return .offline("Ollama: \(error.localizedDescription)")
    }

    static func single(_ event: AnswerEvent) -> AsyncStream<AnswerEvent> {
        AsyncStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }
}
