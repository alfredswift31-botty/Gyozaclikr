import Foundation

// Claude through the Claude Code CLI that is installed and signed in on
// this Mac, run once per request as a subprocess: the owner's login, the
// owner's plan, no API key, no SDK (the pattern the owner's Flow app uses).
// The binary is found by absolute path (apps launched from Finder have no
// shell PATH), run with the flags that skip MCP servers, slash commands,
// settings and session files, stdin on /dev/null (or it waits for input),
// a timeout that terminates it, and its stdout parsed as one JSON object.
// Everything sent here leaves the Mac; the box's label says so.

/// The command: pure, so the shape is tested without the binary.
nonisolated enum ClaudeCLI {
    /// Checked in order; the first executable one is used.
    static let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    static let defaultModel = "claude-sonnet-5-5"
    /// A call takes 2.5–6 s; past this the process is terminated.
    static let timeout: TimeInterval = 60
    static let needsCLI = "Needs the claude CLI: install Claude Code (it goes to /opt/homebrew/bin/claude) and sign in with `claude` then /login."
    static let signIn = "Claude Code isn't signed in. Run `claude` in Terminal and use /login."

    static func binary(executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates.first(where: executable)
    }

    /// The model as typed in Settings, or the default when empty.
    static func normalisedModel(_ raw: String?) -> String {
        let model = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? defaultModel : model
    }

    /// Flow's flags, in Flow's order: the first four skip what each call
    /// doesn't need and would otherwise cost seconds.
    static func arguments(model: String, prompt: String) -> [String] {
        ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "",
         "--model", model, "-p", prompt, "--output-format", "json"]
    }

    /// One prompt: the instructions, the output rule, a `---` line, the user's part.
    static func prompt(instructions: String, user: String) -> String {
        instructions + "\n\nOutput only the result, with no preamble and no closing remark.\n\n---\n\n" + user
    }

    /// What the CLI printed: `result`, `is_error`, `subtype`.
    struct Output: Hashable, Sendable {
        var result: String
        var isError: Bool
        var subtype: String?
    }

    static func parse(_ data: Data) -> Output? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Output(result: (object["result"] as? String) ?? "",
                      isError: (object["is_error"] as? Bool) ?? false,
                      subtype: object["subtype"] as? String)
    }

    /// The answer, or the failure. `is_error` is checked on its own: an
    /// expired login comes back as `is_error: true, subtype: "success"` with
    /// the error text in `result`, which must never be shown as an answer.
    static func outcome(_ output: Output?, exitStatus: Int32, timedOut: Bool) -> Result<String, EngineFailure> {
        if timedOut { return .failure(.offline("Claude Code didn't answer within \(Int(timeout)) s.")) }
        guard let output else {
            return .failure(.offline(exitStatus == 0 ? "Claude Code printed no JSON." : "Claude Code exited with status \(exitStatus) and no JSON."))
        }
        if output.isError || output.subtype != "success" {
            if output.result.localizedCaseInsensitiveContains("authenticat") { return .failure(.unavailable(signIn)) }
            let why = output.result.isEmpty ? "subtype \(output.subtype ?? "none"), status \(exitStatus)" : output.result
            return .failure(.offline("Claude Code: \(why)"))
        }
        let text = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.offline("Claude Code returned an empty answer.")) }
        return .success(text)
    }

    /// Runs the binary once, off the main thread: stdin from /dev/null,
    /// stderr dropped, stdout read to the end even on a non-zero exit, the
    /// process terminated at the timeout or when the task is cancelled.
    static func run(binary: String, arguments: [String], timeout: TimeInterval = timeout,
                    workingDirectory: URL = FileManager.default.temporaryDirectory) async throws -> (stdout: Data, exitStatus: Int32, timedOut: Bool) {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = arguments
                    process.currentDirectoryURL = workingDirectory
                    process.standardInput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    handle.process = process
                    let watchdog = DispatchWorkItem {
                        handle.timedOut = true
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    watchdog.cancel()
                    continuation.resume(returning: (data, process.terminationStatus, handle.timedOut))
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// The running process, reachable from the watchdog and the cancel handler.
    final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var _process: Process?
        private var _timedOut = false
        var process: Process? {
            get { lock.withLock { _process } }
            set { lock.withLock { _process = newValue } }
        }
        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }
        func terminate() {
            let process = self.process
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

/// The Claude engine. Text, and an image by way of a temporary PNG the CLI
/// reads; no structured output, no tools of ours.
nonisolated struct ClaudeEngine: LanguageEngine {
    let kind: EngineKind = .claude
    let capabilities: Set<EngineCapability> = [.text, .image]

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    var model: String { ClaudeCLI.normalisedModel(defaults.string(forKey: SettingsKey.claudeModel)) }
    var binary: String? { ClaudeCLI.binary() }
    var isInstalled: Bool { binary != nil }

    func status() async -> EngineStatus {
        isInstalled ? .ready : .unavailable(ClaudeCLI.needsCLI)
    }

    func prewarm() async {}

    func transform(prompt: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        let user = Prompts.userPrompt(prompt, selection: selection.text)
        return send(instructions: Prompts.instructions, user: user, image: nil, kind: .text)
    }

    func extract(prompt: String, selection: Selection, asCSV: Bool) -> AsyncStream<AnswerEvent> {
        let format = asCSV
            ? "Answer with CSV lines only: one row per line, cells separated by commas, a header row first."
            : "Answer with a bulleted list only, one item per line, each item taken from the text."
        let user = Prompts.userPrompt(prompt + "\n" + format, selection: selection.text)
        return send(instructions: Prompts.instructions, user: user, image: nil, kind: asCSV ? .csv : .extraction)
    }

    func describeImage(question: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        guard let payload = selection.image else {
            return OllamaEngine.single(.failed(.other("There is no image in the selection.")))
        }
        let user = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Describe this image." : question
        let png = ImageScaling.scaledPNG(from: payload)
        return send(instructions: Prompts.describeInstructions, user: user, image: png, kind: .description)
    }

    func agent(request: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        OllamaEngine.single(.failed(.other("Tools run on Apple's model.")))
    }

    /// The Settings pane's Test button: one call, the word OK expected; what
    /// came back and how long it took, in one line.
    func selfTest() async -> String {
        guard let binary else { return ClaudeCLI.needsCLI }
        let started = Date()
        let prompt = ClaudeCLI.prompt(instructions: "You answer with one word.", user: "Reply with the single word OK.")
        do {
            let run = try await ClaudeCLI.run(binary: binary, arguments: ClaudeCLI.arguments(model: model, prompt: prompt))
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            switch ClaudeCLI.outcome(ClaudeCLI.parse(run.stdout), exitStatus: run.exitStatus, timedOut: run.timedOut) {
            case .success(let text): return "ok · \(seconds) s · \(model) · said “\(text.prefix(40))”"
            case .failure(let failure): return "failed · \(seconds) s · \(failure.message)"
            }
        } catch {
            return "failed · \(error.localizedDescription)"
        }
    }

    // MARK: Process

    private func send(instructions: String, user: String, image: Data?, kind: Answer.Kind) -> AsyncStream<AnswerEvent> {
        let model = model
        let binary = binary
        return AsyncStream { continuation in
            let task = Task {
                await self.run(binary: binary, model: model, instructions: instructions, user: user, image: image, kind: kind, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(binary: String?, model: String, instructions: String, user: String, image: Data?, kind: Answer.Kind,
                     continuation: AsyncStream<AnswerEvent>.Continuation) async {
        guard let binary else {
            continuation.yield(.failed(.unavailable(ClaudeCLI.needsCLI)))
            return
        }
        continuation.yield(.status("Asking Claude…"))
        var userPart = user
        var imageFile: URL?
        if let image {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("gyozaclikr-\(UUID().uuidString).png")
            do {
                try image.write(to: url, options: .completeFileProtection)
                imageFile = url
                userPart = "First read the image file at \(url.path) with your Read tool; the question is about that image.\n\n" + user
            } catch {
                continuation.yield(.failed(.other("Couldn't write the image for Claude Code: \(error.localizedDescription)")))
                return
            }
        }
        defer { if let imageFile { try? FileManager.default.removeItem(at: imageFile) } }
        let prompt = ClaudeCLI.prompt(instructions: instructions, user: userPart)
        do {
            let run = try await ClaudeCLI.run(binary: binary, arguments: ClaudeCLI.arguments(model: model, prompt: prompt))
            if Task.isCancelled { continuation.yield(.failed(.cancelled)); return }
            switch ClaudeCLI.outcome(ClaudeCLI.parse(run.stdout), exitStatus: run.exitStatus, timedOut: run.timedOut) {
            case .success(let text):
                continuation.yield(.token(text))
                continuation.yield(.done(Answer(text: text, kind: kind, engine: .claude)))
            case .failure(let failure):
                continuation.yield(.failed(failure))
            }
        } catch {
            continuation.yield(.failed(Task.isCancelled ? .cancelled : .offline("Claude Code couldn't start: \(error.localizedDescription)")))
        }
    }
}
