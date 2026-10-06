import CoreGraphics
import Foundation
import FoundationModels

// Apple's on-device model, carried over from GyozaYap: the availability
// messages, the GenerationError mapping, guided generation with a quote per
// item, map-reduce for long text. One fresh session per request.

/// Whether Apple's on-device model can be used right now, and if not, what
/// the user can do about it. GyozaYap's four messages.
nonisolated enum AppleIntelligenceStatus: Equatable, Sendable {
    case ready
    case unavailable(String)

    static var current: AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in System Settings to use it on this Mac.")
            case .deviceNotEligible:
                return .unavailable("This Mac can't run Apple Intelligence (it needs Apple silicon).")
            case .modelNotReady:
                return .unavailable("Apple Intelligence is still downloading its model. Try again in a little while.")
            @unknown default:
                return .unavailable("Apple Intelligence isn't available right now.")
            }
        @unknown default:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    var engineStatus: EngineStatus {
        switch self {
        case .ready: .ready
        case .unavailable(let message): .unavailable(message)
        }
    }
}

/// Maps the framework's errors to the sentences the box shows, as GyozaYap's NotesService does.
nonisolated enum AppleErrors {
    /// `tokens` and `limit` fill the overflow sentence, since the error carries no numbers.
    static func failure(for error: Error, tokens: Int = 0, limit: Int = SelectionBudget.ceiling) -> EngineFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? EngineFailure { return failure }
        if let generation = error as? LanguageModelSession.GenerationError {
            return failure(for: generation, tokens: tokens, limit: limit)
        }
        if let toolCall = error as? LanguageModelSession.ToolCallError {
            return failure(for: toolCall.underlyingError, tokens: tokens, limit: limit)
        }
        #if SDK_MACOS27
        if #available(macOS 27, *) {
            if let modelError = error as? LanguageModelError {
                return failure(for: modelError, tokens: tokens, limit: limit)
            }
            if case .assetsUnavailable = error as? SystemLanguageModel.Error {
                return .unavailable("Apple Intelligence's model isn't ready yet. Try again in a little while.")
            }
            if error is LanguageModelSession.Error {
                return .rateLimited
            }
        }
        #endif
        return .other(error.localizedDescription)
    }

    static func failure(for error: LanguageModelSession.GenerationError, tokens: Int = 0, limit: Int = SelectionBudget.ceiling) -> EngineFailure {
        switch error {
        case .guardrailViolation: .refused
        case .exceededContextWindowSize: .tooLong(tokens: tokens, limit: limit)
        case .assetsUnavailable: .unavailable("Apple Intelligence's model isn't ready yet. Try again in a little while.")
        case .rateLimited, .concurrentRequests: .rateLimited
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .refusal: .refused
        default: .other(error.localizedDescription)
        }
    }

}

#if SDK_MACOS27
// `nonisolated` again: an extension does not inherit it from the enum.
nonisolated extension AppleErrors {
    /// The macOS 27 error family (Xcode 27 builds catch these instead of
    /// `GenerationError`), same sentences. The overflow error carries its own numbers.
    @available(macOS 27, *)
    static func failure(for error: LanguageModelError, tokens: Int = 0, limit: Int = SelectionBudget.ceiling) -> EngineFailure {
        switch error {
        case .guardrailViolation: .refused
        case .contextSizeExceeded(let details): .tooLong(tokens: tokens > 0 ? tokens : details.tokenCount, limit: min(limit, details.contextSize))
        case .rateLimited: .rateLimited
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .refusal: .refused
        case .unsupportedCapability: .unavailable("Apple's model on this Mac doesn't support this kind of request.")
        default: .other(error.localizedDescription)
        }
    }
}
#endif

// MARK: - Guided generation types

@Generable
nonisolated struct ExtractedItem {
    @Guide(description: "the item")
    var text: String
    @Guide(description: "the exact words in the text this comes from")
    var quote: String
}

@Generable
nonisolated struct Extraction {
    @Guide(description: "the items found; empty when there are none", .maximumCount(12))
    var items: [ExtractedItem]
}

@Generable
nonisolated struct ExtractedRow {
    @Guide(description: "the cells of this row, in column order")
    var cells: [String]
    @Guide(description: "the exact words in the text this row comes from")
    var quote: String
}

@Generable
nonisolated struct TableExtraction {
    @Guide(description: "the header row first, then one row per record", .maximumCount(40))
    var rows: [ExtractedRow]
}

@Generable
nonisolated struct ImageDescription {
    @Guide(description: "what the image mainly shows, one sentence")
    var subject: String
    @Guide(description: "where or in what context, one short sentence; empty if unclear")
    var setting: String
    @Guide(description: "any text that matters, as written; empty if none")
    var visibleText: String
    @Guide(description: "what you can't tell; empty if nothing")
    var uncertainty: String
}

/// Renders a description's fields as two or three plain sentences.
nonisolated enum DescriptionText {
    static func render(subject: String, setting: String, visibleText: String, uncertainty: String) -> String {
        var sentences: [String] = []
        func sentence(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !["none", "n/a", "nothing", "unclear"].contains(trimmed.lowercased()) else { return nil }
            return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? trimmed : trimmed + "."
        }
        if let subject = sentence(subject) { sentences.append(subject) }
        if let setting = sentence(setting) { sentences.append(setting) }
        if let text = sentence(visibleText) { sentences.append("Text: " + text) }
        if sentences.count < 3, let uncertainty = sentence(uncertainty) { sentences.append(uncertainty) }
        return sentences.joined(separator: " ")
    }
}

/// The one-word answer the launch probe asks for.
@Generable
nonisolated struct ColourAnswer {
    @Guide(description: "the colour of the image, one word")
    var colour: String
}

// MARK: - The engine

/// Apple's on-device model. `imageSupport` is the launch probe's result:
/// only `.supported` on macOS 27 with the macOS 27 SDK adds `.image`.
nonisolated struct AppleEngine: LanguageEngine {
    let kind: EngineKind = .apple
    let capabilities: Set<EngineCapability>
    let imageSupport: ImageSupport

    init(imageSupport: ImageSupport = .untested) {
        self.imageSupport = imageSupport
        var capabilities: Set<EngineCapability> = [.text, .structured, .tools]
        #if SDK_MACOS27
        if #available(macOS 27, *), imageSupport == .supported {
            capabilities.insert(.image)
        }
        #endif
        self.capabilities = capabilities
    }

    static let imageUnavailable = "Apple's model takes images on macOS 27 and a build with the macOS 27 SDK."

    func status() async -> EngineStatus {
        AppleIntelligenceStatus.current.engineStatus
    }

    func prewarm() async {
        guard AppleIntelligenceStatus.current == .ready else { return }
        LanguageModelSession(model: Self.transformModel, instructions: Prompts.instructions).prewarm()
    }

    func transform(prompt: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        stream { continuation in
            try await Self.transform(prompt: prompt, text: selection.text ?? "", continuation: continuation)
        }
    }

    func extract(prompt: String, selection: Selection, asCSV: Bool) -> AsyncStream<AnswerEvent> {
        stream { continuation in
            try await Self.extract(prompt: prompt, text: selection.text ?? "", asCSV: asCSV, continuation: continuation)
        }
    }

    func describeImage(question: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        stream { continuation in
            #if SDK_MACOS27
            if #available(macOS 27, *) {
                guard let payload = selection.image, let image = ImageScaling.cgImage(from: payload) else {
                    continuation.yield(.failed(.other("There is no image in the selection.")))
                    return
                }
                continuation.yield(.status("Looking…"))
                let question = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Describe this image." : question
                let description = try await Self.describeWithAttachment(question: question, image: ImageScaling.downscaled(image))
                let text = DescriptionText.render(
                    subject: description.subject, setting: description.setting,
                    visibleText: description.visibleText, uncertainty: description.uncertainty
                )
                continuation.yield(.token(text))
                continuation.yield(.done(Answer(text: text, kind: .description, engine: .apple)))
                return
            }
            #endif
            continuation.yield(.failed(.unavailable(Self.imageUnavailable)))
        }
    }

    func agent(request: String, selection: Selection) -> AsyncStream<AnswerEvent> {
        stream { continuation in
            try await Self.agent(request: request, text: selection.text ?? "", continuation: continuation)
        }
    }

    // MARK: Sessions

    /// String transforms skip the guardrails that reject news and medical text; guided generation keeps them.
    static var transformModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// The status word for a prompt: the chip's verb, or "Reading…" for free text.
    static func statusVerb(for prompt: String) -> String {
        Chip.allCases.first { Prompts.prompt(for: $0) == prompt }?.statusVerb ?? "Reading…"
    }

    static func contextSize() -> Int {
        if #available(macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return SelectionBudget.defaultContextSize
    }

    /// The model's own count on macOS 26.4 and later, else the estimate.
    static func tokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, *) {
            let count = try? await SystemLanguageModel.default.tokenCount(for: text)
            if let count { return count }
        }
        return SelectionBudget.estimate(text)
    }

    /// The selection budget for this prompt, with the selection's count.
    static func budget(prompt: String, text: String) async -> (tokens: Int, limit: Int) {
        let instructions = await tokenCount(Prompts.instructions)
        let promptTokens = await tokenCount(prompt + "\n\n" + Prompts.wrap(""))
        let tokens = await tokenCount(text)
        return (tokens, SelectionBudget.limit(contextSize: contextSize(), instructionTokens: instructions, promptTokens: promptTokens))
    }

    private static func transform(prompt: String, text: String, continuation: AsyncStream<AnswerEvent>.Continuation) async throws {
        try requireReady()
        continuation.yield(.status(statusVerb(for: prompt)))
        let (tokens, limit) = await budget(prompt: prompt, text: text)
        var material = text
        if tokens > limit {
            guard SelectionBudget.isSummaryLike(prompt) else {
                throw EngineFailure.tooLong(tokens: tokens, limit: limit)
            }
            material = try await condense(text, prompt: prompt, limit: limit, continuation: continuation)
            continuation.yield(.status(statusVerb(for: prompt)))
        }
        do {
            let answer = try await streamText(Prompts.userPrompt(prompt, selection: material), continuation: continuation)
            continuation.yield(.done(Answer(text: answer, kind: .text, engine: .apple)))
        } catch {
            throw AppleErrors.failure(for: error, tokens: tokens, limit: limit)
        }
    }

    /// Map-reduce as GyozaYap: each part answered in a fresh session, the
    /// parts joined, and joined again until they fit the final pass.
    private static func condense(_ text: String, prompt: String, limit: Int, continuation: AsyncStream<AnswerEvent>.Continuation) async throws -> String {
        var material = text
        for _ in 0..<4 {
            let chunks = await Chunker.chunks(of: material, budget: limit, tokens: tokenCount)
            guard chunks.count > 1 else { break }
            var parts: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                continuation.yield(.status("Reading part \(index + 1) of \(chunks.count)…"))
                let session = LanguageModelSession(model: transformModel, instructions: Prompts.instructions)
                do {
                    let response = try await session.respond(to: Prompts.userPrompt(prompt, selection: chunk))
                    parts.append(response.content)
                } catch {
                    throw AppleErrors.failure(for: error, tokens: await tokenCount(chunk), limit: limit)
                }
            }
            material = parts.joined(separator: "\n\n")
            if await tokenCount(material) <= limit { return material }
        }
        return material
    }

    /// Streams one answer, emitting each new suffix of the snapshot.
    private static func streamText(_ prompt: String, continuation: AsyncStream<AnswerEvent>.Continuation) async throws -> String {
        let session = LanguageModelSession(model: transformModel, instructions: Prompts.instructions)
        var emitted = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            let content = snapshot.content
            if content.hasPrefix(emitted) {
                let delta = String(content.dropFirst(emitted.count))
                if !delta.isEmpty { continuation.yield(.token(delta)) }
            }
            emitted = content
        }
        return emitted
    }

    private static func extract(prompt: String, text: String, asCSV: Bool, continuation: AsyncStream<AnswerEvent>.Continuation) async throws {
        try requireReady()
        continuation.yield(.status("Extracting…"))
        let (tokens, limit) = await budget(prompt: prompt, text: text)
        guard tokens <= limit else { throw EngineFailure.tooLong(tokens: tokens, limit: limit) }
        let session = LanguageModelSession(instructions: Prompts.instructions)
        let fullPrompt = Prompts.userPrompt(prompt, selection: text)
        let options = GenerationOptions(sampling: .greedy)
        do {
            if asCSV {
                let response = try await session.respond(to: fullPrompt, generating: TableExtraction.self, options: options)
                let rows = response.content.rows.map { ExtractedTableRow(cells: $0.cells, quote: $0.quote) }
                let verified = Verification.keep(rows, in: text)
                let answer = CSV.render(rows: verified.kept.map(\.cells))
                continuation.yield(.token(answer))
                continuation.yield(.done(Answer(text: answer, kind: .csv, engine: .apple, dropped: verified.dropped, kept: verified.kept.count)))
            } else {
                let response = try await session.respond(to: fullPrompt, generating: Extraction.self, options: options)
                let items = response.content.items.map { ExtractedQuote(text: $0.text, quote: $0.quote) }
                let verified = Verification.keep(items, in: text)
                let answer = Verification.bullets(verified.kept)
                continuation.yield(.token(answer))
                continuation.yield(.done(Answer(text: answer, kind: .extraction, engine: .apple, dropped: verified.dropped, kept: verified.kept.count)))
            }
        } catch {
            throw AppleErrors.failure(for: error, tokens: tokens, limit: limit)
        }
    }

    #if SDK_MACOS27
    /// The image path: the question and the image in one prompt, a
    /// constrained description back. Only compiled with the macOS 27 SDK.
    @available(macOS 27, *)
    static func describeWithAttachment(question: String, image: CGImage) async throws -> ImageDescription {
        let session = LanguageModelSession(instructions: Prompts.describeInstructions)
        do {
            let response = try await session.respond(generating: ImageDescription.self, options: GenerationOptions(sampling: .greedy)) {
                Prompt(question)
                Attachment(image)
            }
            return response.content
        } catch {
            throw AppleErrors.failure(for: error)
        }
    }

    /// The launch probe: a solid colour in, one word out, so the Engines pane
    /// can say whether this Mac's model takes an image at all.
    @available(macOS 27, *)
    static func probeImageInput(image: CGImage) async throws -> String {
        let session = LanguageModelSession(instructions: "You answer with one word.")
        do {
            let response = try await session.respond(generating: ColourAnswer.self, options: GenerationOptions(sampling: .greedy)) {
                "What colour is this image?"
                Attachment(image)
            }
            return response.content.colour
        } catch {
            throw AppleErrors.failure(for: error)
        }
    }
    #endif

    private static func agent(request: String, text: String, continuation: AsyncStream<AnswerEvent>.Continuation) async throws {
        try requireReady()
        continuation.yield(.status("Reading…"))
        let log = ProposalLog()
        let tools: [any Tool] = [SendMailTool(log: log), CreateReminderTool(log: log), CreateEventTool(log: log), SaveNoteTool(log: log)]
        let session = LanguageModelSession(tools: tools, instructions: Prompts.agentInstructions)
        let prompt = Prompts.userPrompt(request, selection: text)
        let answer: String
        do {
            answer = try await session.respond(to: prompt).content
        } catch {
            throw AppleErrors.failure(for: error, tokens: await tokenCount(text))
        }
        for event in agentEvents(text: answer, proposals: await log.proposals) {
            continuation.yield(event)
        }
    }

    /// What the box gets after an agent turn. Pure, so the policy is tested:
    /// one proposal is confirmed; more than one keeps the first (the app
    /// refuses a second outward action per request); a question with no
    /// proposal asks the user; anything else is text.
    static func agentEvents(text: String, proposals: [ActionProposal]) -> [AnswerEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = proposals.first {
            var events: [AnswerEvent] = []
            if proposals.count > 1 {
                events.append(.status("Only the first action is proposed; \(proposals.count - 1) more were ignored."))
            }
            events.append(.needsConfirmation(first))
            return events
        }
        if trimmed.hasSuffix("?") {
            return [.askUser(question: trimmed, options: [])]
        }
        return [.token(trimmed), .done(Answer(text: trimmed, kind: .text, engine: .apple))]
    }

    // MARK: Plumbing

    private static func requireReady() throws {
        if case .unavailable(let message) = AppleIntelligenceStatus.current {
            throw EngineFailure.unavailable(message)
        }
    }

    /// Runs `body` in its own task; a thrown error becomes `.failed`, and a
    /// consumer that stops listening cancels the generation.
    private func stream(_ body: @escaping @Sendable (AsyncStream<AnswerEvent>.Continuation) async throws -> Void) -> AsyncStream<AnswerEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                } catch {
                    continuation.yield(.failed(Task.isCancelled ? .cancelled : AppleErrors.failure(for: error)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
