import CoreGraphics
import Foundation
import FoundationModels
import Testing
@testable import Gyozaclikr

// The Engine module without the live model: the wire formats, the maths and
// the policies are pure and tested here; what needs Apple's model or Ollama
// is measured on the runner and written to a file CI prints.

/// Facts measured on the runner, printed by the workflow after the tests.
enum EngineMeasurements {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozaclikr-measurements", isDirectory: true)

    static func note(_ line: String) {
        print("[measure] \(line)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("engine.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Collects a stream's events for assertions.
func collect(_ stream: AsyncStream<AnswerEvent>) async -> [AnswerEvent] {
    var events: [AnswerEvent] = []
    for await event in stream { events.append(event) }
    return events
}

// MARK: - Verification and CSV

struct VerificationTests {
    let selection = "Dentist on Thursday at 3pm,\n  Hauptstrasse 12.\nBring the “insurance card”."

    @Test func anExactQuoteIsKept() {
        let result = Verification.keep([ExtractedQuote(text: "Dentist", quote: "Dentist on Thursday at 3pm")], in: selection)
        #expect(result.kept.count == 1)
        #expect(result.dropped == 0)
    }

    @Test func whitespaceAndCaseDifferencesAreKept() {
        let items = [
            ExtractedQuote(text: "address", quote: "hauptstrasse   12"),
            ExtractedQuote(text: "time", quote: "THURSDAY AT 3PM,\nHauptstrasse 12"),
            ExtractedQuote(text: "card", quote: "the \"insurance card\""),
        ]
        let result = Verification.keep(items, in: selection)
        #expect(result.kept.map(\.text) == ["address", "time", "card"])
        #expect(result.dropped == 0)
    }

    @Test func aQuoteNotInTheSelectionIsDropped() {
        let items = [
            ExtractedQuote(text: "Dentist", quote: "Dentist on Thursday"),
            ExtractedQuote(text: "invented", quote: "call the clinic first"),
            ExtractedQuote(text: "no source", quote: ""),
        ]
        let result = Verification.keep(items, in: selection)
        #expect(result.kept.map(\.text) == ["Dentist"])
        #expect(result.dropped == 2)
        #expect(Verification.bullets(result.kept) == "- Dentist")
    }

    @Test func rowsAreVerifiedByTheirQuote() {
        let rows = [
            ExtractedTableRow(cells: ["Dentist", "Thursday"], quote: "Dentist on Thursday"),
            ExtractedTableRow(cells: ["Doctor", "Friday"], quote: "Doctor on Friday"),
        ]
        let result = Verification.keep(rows, in: selection)
        #expect(result.kept.count == 1)
        #expect(result.dropped == 1)
    }
}

struct CSVTests {
    @Test func plainCellsAreNotQuoted() {
        #expect(CSV.render(rows: [["a", "b"], ["1", "2"]]) == "a,b\n1,2")
    }

    @Test func commasQuotesAndLineBreaksAreQuotedPerRFC4180() {
        #expect(CSV.field("Hello, world") == "\"Hello, world\"")
        #expect(CSV.field("She said \"hi\"") == "\"She said \"\"hi\"\"\"")
        #expect(CSV.field("two\nlines") == "\"two\nlines\"")
        #expect(CSV.render(rows: [["x,y", "plain"]]) == "\"x,y\",plain")
    }
}

// MARK: - Chunking and budgets

struct ChunkingTests {
    /// Words as tokens: predictable and close enough to the real ratio for the maths.
    let words: (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count }

    @Test func paragraphsSplitOnBlankLines() {
        let text = "one two\nthree\n\n   \nfour five\n\n\n\nsix\n"
        #expect(Chunker.paragraphs(of: text) == ["one two\nthree", "four five", "six"])
    }

    @Test func paragraphsPackUpToTheBudget() async {
        let text = "a b c\n\nd e f\n\ng h i"
        let tight = await Chunker.chunks(of: text, budget: 5, tokens: words)
        #expect(tight == ["a b c", "d e f", "g h i"])
        // Two paragraphs of three words plus one for the join is seven.
        let wide = await Chunker.chunks(of: text, budget: 7, tokens: words)
        #expect(wide == ["a b c\n\nd e f", "g h i"])
        let all = await Chunker.chunks(of: text, budget: 100, tokens: words)
        #expect(all == [text])
    }

    @Test func anOversizedParagraphIsSplitWithoutLosingWords() async {
        let line = (1...40).map { "w\($0)" }.joined(separator: " ")
        let chunks = await Chunker.chunks(of: line, budget: 6, tokens: words)
        #expect(chunks.count >= 7)
        for chunk in chunks { #expect(words(chunk) <= 6) }
        let rejoined = chunks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(rejoined == line.split(separator: " ").map(String.init))
    }

    @Test func theBudgetLeavesRoomForInstructionsAndTheAnswer() {
        // 4096 − 120 − 40 − 600 = 3336, capped at the ceiling.
        #expect(SelectionBudget.limit(contextSize: 4_096, instructionTokens: 120, promptTokens: 40) == 2_600)
        #expect(SelectionBudget.limit(contextSize: 2_000, instructionTokens: 120, promptTokens: 40) == 1_240)
        #expect(SelectionBudget.limit(contextSize: 500, instructionTokens: 120, promptTokens: 40) == 0)
    }

    @Test func theEstimateUsesThreeAndAHalfCharactersPerToken() {
        #expect(SelectionBudget.estimate("") == 0)
        #expect(SelectionBudget.estimate("abc") == 1)
        #expect(SelectionBudget.estimate(String(repeating: "x", count: 350)) == 100)
    }

    @Test func onlySummaryPromptsAreChunked() {
        #expect(SelectionBudget.isSummaryLike(Prompts.prompt(for: .summarise)))
        #expect(SelectionBudget.isSummaryLike("Give me the TL;DR"))
        // "register" contains "gist"; only whole words count.
        #expect(!SelectionBudget.isSummaryLike(Prompts.prompt(for: .formal)))
        #expect(SelectionBudget.isSummaryLike("what's the gist?"))
        #expect(!SelectionBudget.isSummaryLike("make it a formal rewrite of the register"))
        #expect(!SelectionBudget.isSummaryLike(Prompts.prompt(for: .fix)))
    }
}

// MARK: - Ollama wire format

struct OllamaRequestTests {
    func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aTextRequestCarriesModelStreamKeepAliveAndSystem() throws {
        let request = try #require(OllamaRequest.chat(host: "http://127.0.0.1:11434", model: "llama3", system: "Be brief.", user: "Hi"))
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request.httpMethod == "POST")
        let json = try body(of: request)
        #expect(json["model"] as? String == "llama3")
        #expect(json["stream"] as? Bool == true)
        #expect(json["keep_alive"] as? String == "10m")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Be brief.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hi")
        #expect(messages[1]["images"] == nil)
    }

    @Test func anImageRequestCarriesOneBase64Image() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let request = try #require(OllamaRequest.chat(host: "127.0.0.1:11434", model: "qwen3-vl", system: "s", user: "What is this?", imagePNG: png))
        let json = try body(of: request)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[1]["images"] as? [String] == [png.base64EncodedString()])
        #expect(messages[0]["images"] == nil)
    }

    @Test func hostsGetASchemeAndLoseTrailingSlashes() {
        #expect(OllamaRequest.normalisedHost("http://127.0.0.1:11434/") == "http://127.0.0.1:11434")
        #expect(OllamaRequest.normalisedHost("mini.local:11434") == "http://mini.local:11434")
        #expect(OllamaRequest.normalisedHost("  https://ollama.example.com//  ") == "https://ollama.example.com")
        #expect(OllamaRequest.normalisedHost(nil) == OllamaRequest.defaultHost)
        #expect(OllamaRequest.normalisedHost("") == "http://127.0.0.1:11434")
        #expect(OllamaRequest.tags(host: "localhost:11434/")?.url?.absoluteString == "http://localhost:11434/api/tags")
        #expect(OllamaRequest.tags(host: "localhost:11434")?.timeoutInterval == 2)
    }

    @Test func onlyLoopbackHostsCountAsLocal() {
        #expect(OllamaRequest.isLocal("http://127.0.0.1:11434"))
        #expect(OllamaRequest.isLocal("localhost:11434"))
        #expect(!OllamaRequest.isLocal("http://mini.local:11434"))
    }

    @Test func modelsArePickedFromTheTagList() {
        let tags = ["llama3.2:3b", "qwen3-vl:8b", "hermes3:8b", "llava:latest"]
        #expect(OllamaModels.visionModel(from: tags) == "qwen3-vl:8b")
        #expect(OllamaModels.textModel(from: tags) == "llama3.2:3b")
        #expect(OllamaModels.visionModel(from: []) == "qwen3-vl")
        #expect(OllamaModels.textModel(from: ["minicpm-vision"]) == "minicpm-vision")
        let json = Data(#"{"models":[{"name":"a:1","size":1},{"name":"b-vl:2"}]}"#.utf8)
        #expect(OllamaModels.names(fromTagsJSON: json) == ["a:1", "b-vl:2"])
    }
}

struct OllamaStreamParserTests {
    let fixture = """
        {"model":"qwen3-vl","message":{"role":"assistant","content":"A "},"done":false}
        {"model":"qwen3-vl","message":{"role":"assistant","content":"héllo"},"done":false}
        {"model":"qwen3-vl","message":{"role":"assistant","content":" world"},"done":false}
        {"model":"qwen3-vl","message":{"role":"assistant","content":""},"done":true,"eval_count":3}

        """

    @Test func wholeStreamParsesToChunks() {
        var parser = OllamaStreamParser()
        let chunks = parser.feed(Data(fixture.utf8))
        #expect(chunks.map(\.content) == ["A ", "héllo", " world", ""])
        #expect(chunks.map(\.done) == [false, false, false, true])
        #expect(parser.finish().isEmpty)
    }

    @Test func splitsMidLineAndMidUTF8ProduceTheSameChunks() {
        let bytes = Array(fixture.utf8)
        // Every split point, including the one inside the two-byte "é".
        let eIndex = bytes.firstIndex(of: 0xC3)!
        for cut in [1, 20, eIndex + 1, eIndex, bytes.count - 1] {
            var parser = OllamaStreamParser()
            var chunks = parser.feed(Data(bytes[..<cut]))
            chunks += parser.feed(Data(bytes[cut...]))
            chunks += parser.finish()
            #expect(chunks.map(\.content) == ["A ", "héllo", " world", ""], "cut at \(cut)")
            #expect(chunks.last?.done == true)
        }
    }

    @Test func byteAtATimeFeedingWorks() {
        var parser = OllamaStreamParser()
        var chunks: [OllamaChunk] = []
        for byte in fixture.utf8 { chunks += parser.feed(Data([byte])) }
        #expect(chunks.map(\.content).joined() == "A héllo world")
    }

    @Test func aTrailingLineWithoutNewlineArrivesOnFinish() {
        var parser = OllamaStreamParser()
        #expect(parser.feed(Data(#"{"message":{"content":"x"},"done":true}"#.utf8)).isEmpty)
        #expect(parser.finish().map(\.content) == ["x"])
    }

    @Test func anErrorLineIsReported() {
        var parser = OllamaStreamParser()
        let chunks = parser.feed(Data("{\"error\":\"model 'x' not found\"}\n".utf8))
        #expect(chunks.first?.error == "model 'x' not found")
        #expect(chunks.first?.done == true)
    }
}

// MARK: - Images

struct ImageScalingTests {
    @Test func theLongSideIsLimitedAndAspectKept() throws {
        let wide = try #require(ImageScaling.solidColour(width: 2_048, height: 1_024, red: 1, green: 0, blue: 0))
        let scaled = ImageScaling.downscaled(wide, longSide: 1_024)
        #expect(scaled.width == 1_024)
        #expect(scaled.height == 512)
        let tall = try #require(ImageScaling.solidColour(width: 300, height: 900, red: 0, green: 1, blue: 0))
        let scaledTall = ImageScaling.downscaled(tall, longSide: 300)
        #expect(scaledTall.width == 100)
        #expect(scaledTall.height == 300)
    }

    @Test func aSmallImageIsReturnedUnchanged() throws {
        let small = try #require(ImageScaling.solidColour(width: 16, height: 16, red: 1, green: 0, blue: 0))
        #expect(ImageScaling.downscaled(small, longSide: 1_024) === small)
    }

    @Test func pngRoundTripKeepsTheSize() throws {
        let image = try #require(ImageScaling.solidColour(width: 40, height: 24, red: 0, green: 0, blue: 1))
        let png = try #require(ImageScaling.png(from: image))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let back = try #require(ImageScaling.cgImage(fromPNG: png))
        #expect(back.width == 40)
        #expect(back.height == 24)
        let payload = try #require(ImageScaling.payload(from: image, scale: 2))
        #expect(payload.pointSize == CGSize(width: 20, height: 12))
        #expect(ImageScaling.scaledPNG(from: payload) == payload.png)
    }

    @Test func scaledPNGShrinksALargePayload() throws {
        let image = try #require(ImageScaling.solidColour(width: 1_500, height: 300, red: 0, green: 0, blue: 1))
        let payload = try #require(ImageScaling.payload(from: image, scale: 2))
        let scaled = try #require(ImageScaling.cgImage(fromPNG: ImageScaling.scaledPNG(from: payload)))
        #expect(scaled.width == 1_024)
        #expect(scaled.height == 205)
    }
}

// MARK: - Apple: error mapping, agent policy, description text

struct AppleErrorMappingTests {
    let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")

    @Test func generationErrorsMapAsNotesServiceDoes() {
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.guardrailViolation(context)) == .refused)
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.exceededContextWindowSize(context), tokens: 6_100, limit: 2_600) == .tooLong(tokens: 6_100, limit: 2_600))
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.assetsUnavailable(context)) == .unavailable("Apple Intelligence's model isn't ready yet. Try again in a little while."))
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.rateLimited(context)) == .rateLimited)
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.concurrentRequests(context)) == .rateLimited)
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)) == .unsupportedLanguage)
        #expect(AppleErrors.failure(for: LanguageModelSession.GenerationError.refusal(.init(transcriptEntries: []), context)) == .refused)
        if case .other = AppleErrors.failure(for: LanguageModelSession.GenerationError.decodingFailure(context)) {} else {
            Issue.record("decodingFailure should map to .other")
        }
    }

    @Test func otherErrorsMapToCancelledOrOther() {
        #expect(AppleErrors.failure(for: CancellationError()) == .cancelled)
        #expect(AppleErrors.failure(for: EngineFailure.tooLong(tokens: 1, limit: 1)) == .tooLong(tokens: 1, limit: 1))
        let generic: Error = LanguageModelSession.GenerationError.guardrailViolation(context)
        #expect(AppleErrors.failure(for: generic) == .refused)
        let wrapped = LanguageModelSession.ToolCallError(tool: SaveNoteTool(log: ProposalLog()), underlyingError: LanguageModelSession.GenerationError.rateLimited(context))
        #expect(AppleErrors.failure(for: wrapped) == .rateLimited)
    }
}

struct AgentPolicyTests {
    let mail = ActionProposal.sendMail(to: ["a@b.c"], subject: "Hi", body: "…")
    let note = ActionProposal.saveNote(title: "n", body: "b")

    @Test func oneProposalIsConfirmed() {
        let events = AppleEngine.agentEvents(text: "Done.", proposals: [mail])
        #expect(events.count == 1)
        guard case .needsConfirmation(let proposal) = events[0] else { Issue.record("expected needsConfirmation"); return }
        #expect(proposal == mail)
    }

    @Test func aSecondProposalIsIgnoredWithAStatusLine() {
        let events = AppleEngine.agentEvents(text: "", proposals: [mail, note])
        #expect(events.count == 2)
        guard case .status(let line) = events[0] else { Issue.record("expected status"); return }
        #expect(line.contains("1 more"))
        guard case .needsConfirmation(let proposal) = events[1] else { Issue.record("expected needsConfirmation"); return }
        #expect(proposal == mail)
    }

    @Test func aQuestionWithoutAProposalAsksTheUser() {
        let events = AppleEngine.agentEvents(text: "Who should I send it to?\n", proposals: [])
        #expect(events.count == 1)
        guard case .askUser(let question, let options) = events[0] else { Issue.record("expected askUser"); return }
        #expect(question == "Who should I send it to?")
        #expect(options.isEmpty)
    }

    @Test func plainTextIsDone() {
        let events = AppleEngine.agentEvents(text: " The gist is X. ", proposals: [])
        #expect(events.count == 2)
        guard case .token(let token) = events[0], case .done(let answer) = events[1] else { Issue.record("expected token then done"); return }
        #expect(token == "The gist is X.")
        #expect(answer.text == "The gist is X.")
        #expect(answer.engine == .apple)
    }

    @Test func toolStringsBecomeProposalFields() async {
        #expect(ToolArguments.recipients("a@b.c, d@e.f g@h.i;j@k.l") == ["a@b.c", "d@e.f", "g@h.i", "j@k.l"])
        #expect(ToolArguments.recipients("") == [])
        #expect(ToolArguments.optional("none") == nil)
        #expect(ToolArguments.optional("  Friday 9am ") == "Friday 9am")
        let log = ProposalLog()
        await log.record(.createReminder(title: "x", due: nil, dueText: nil))
        let recorded = await log.proposals
        #expect(recorded == [.createReminder(title: "x", due: nil, dueText: nil)])
    }

    @Test func toolsAreFourWithFlatNames() {
        let log = ProposalLog()
        let names = [SendMailTool(log: log).name, CreateReminderTool(log: log).name, CreateEventTool(log: log).name, SaveNoteTool(log: log).name]
        #expect(names == ["sendMail", "createReminder", "createEvent", "saveNote"])
    }
}

struct DescriptionTextTests {
    @Test func fieldsBecomeTwoOrThreeSentences() {
        let text = DescriptionText.render(subject: "A potted monstera", setting: "on a windowsill", visibleText: "", uncertainty: "none")
        #expect(text == "A potted monstera. On a windowsill.")
        let road = DescriptionText.render(subject: "a red and a blue car on a road", meaning: "the two-second following distance between cars",
                                          setting: "a road with grass on either side", visibleText: "2 seconds", uncertainty: "")
        #expect(road == "A red and a blue car on a road. The two-second following distance between cars. A road with grass on either side. Text: 2 seconds.")
        let withText = DescriptionText.render(subject: "A terminal window.", setting: "", visibleText: "error: not found", uncertainty: "I can't tell the shell")
        #expect(withText == "A terminal window. Text: error: not found. I can't tell the shell.")
    }
}

// MARK: - The Claude Code CLI, without the binary

struct ClaudeCLITests {
    @Test func binaryIsFoundByAbsolutePathInOrder() {
        #expect(ClaudeCLI.binary(executable: { _ in false }) == nil)
        #expect(ClaudeCLI.binary(executable: { $0 == "/usr/local/bin/claude" }) == "/usr/local/bin/claude")
        #expect(ClaudeCLI.binary(executable: { _ in true }) == "/opt/homebrew/bin/claude", "Homebrew first")
    }

    @Test func argumentsFollowFlowsPattern() {
        let args = ClaudeCLI.arguments(model: "claude-sonnet-5-5", prompt: "P")
        #expect(args == ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "",
                         "--model", "claude-sonnet-5-5", "-p", "P", "--output-format", "json"])
        #expect(ClaudeCLI.normalisedModel("  ") == "claude-sonnet-5-5")
        #expect(ClaudeCLI.normalisedModel("claude-opus-5-5") == "claude-opus-5-5")
        let prompt = ClaudeCLI.prompt(instructions: "Be brief.", user: "Hi")
        #expect(prompt.hasPrefix("Be brief.\n\nYou have no tools in this session"))
        #expect(prompt.contains("Output only the result"))
        #expect(prompt.hasSuffix("\n\n---\n\nHi"))
    }

    @Test func webSearchAllowsTheWebToolsAndSaysSo() {
        let args = ClaudeCLI.arguments(model: "m", prompt: "P", webSearch: true)
        #expect(args.starts(with: ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "", "--allowedTools", "WebSearch,WebFetch", "--model", "m"]))
        #expect(!ClaudeCLI.arguments(model: "m", prompt: "P").contains("--allowedTools"))
        let prompt = ClaudeCLI.prompt(instructions: "I.", user: "price?", webSearch: true)
        #expect(prompt.contains("You may search the web"))
        #expect(!prompt.contains("no tools"))
    }

    @Test func outputIsParsedAndJudged() {
        let ok = ClaudeCLI.parse(Data(#"{"type":"result","subtype":"success","is_error":false,"result":" Dear Dana, …  "}"#.utf8))
        #expect(ok == ClaudeCLI.Output(result: " Dear Dana, …  ", isError: false, subtype: "success"))
        #expect(ClaudeCLI.outcome(ok, exitStatus: 0, timedOut: false) == .success("Dear Dana, …"))

        // The expired-login shape: is_error true under subtype "success"; never an answer.
        let expired = ClaudeCLI.Output(result: "Failed to authenticate: OAuth session expired. Please run /login.", isError: true, subtype: "success")
        #expect(ClaudeCLI.outcome(expired, exitStatus: 1, timedOut: false) == .failure(.unavailable(ClaudeCLI.signIn)))

        let errored = ClaudeCLI.Output(result: "", isError: false, subtype: "error_max_turns")
        #expect(ClaudeCLI.outcome(errored, exitStatus: 1, timedOut: false) == .failure(.offline("Claude Code: subtype error_max_turns, status 1")))
        #expect(ClaudeCLI.outcome(nil, exitStatus: 2, timedOut: false) == .failure(.offline("Claude Code exited with status 2 and no JSON.")))
        #expect(ClaudeCLI.outcome(ok, exitStatus: 0, timedOut: true) == .failure(.offline("Claude Code didn't answer in time.")))
        #expect(ClaudeCLI.parse(Data("not json".utf8)) == nil)
    }

    @Test func enginePrefixesPickAnEngineForOneRequest() {
        #expect(PreRouter.stripEnginePrefix("/claude make it rhyme").text == "make it rhyme")
        #expect(PreRouter.stripEnginePrefix("/claude make it rhyme").engine == .claude)
        #expect(PreRouter.stripEnginePrefix("/local what is this").engine == .ollama)
        #expect(PreRouter.stripEnginePrefix("/apple fix").engine == .apple)
        #expect(PreRouter.stripEnginePrefix("/claudette").engine == nil)
        #expect(PreRouter.stripEnginePrefix("  plain  ") == ("plain", nil))
    }
}

// MARK: - Engine construction and status verbs

struct EngineShapeTests {
    @Test func appleCapabilitiesFollowTheImageProbe() {
        let untested = AppleEngine()
        #expect(untested.kind == .apple)
        #expect(untested.capabilities == [.text, .structured, .tools])
        let supported = AppleEngine(imageSupport: .supported)
        #if SDK_MACOS27
        if #available(macOS 27, *) {
            #expect(supported.capabilities.contains(.image))
        } else {
            #expect(!supported.capabilities.contains(.image))
        }
        #else
        #expect(!supported.capabilities.contains(.image))
        #endif
        let ollama = OllamaEngine()
        #expect(ollama.kind == .ollama)
        #expect(ollama.capabilities == [.text, .image])
        let claude = ClaudeEngine()
        #expect(claude.kind == .claude)
        #expect(claude.capabilities == [.text, .image])
        #expect(EngineKind.allCases == [.apple, .ollama, .claude])
    }

    @Test func statusVerbsComeFromTheChips() {
        #expect(AppleEngine.statusVerb(for: Prompts.prompt(for: .fix)) == "Rewriting…")
        #expect(AppleEngine.statusVerb(for: Prompts.prompt(for: .summarise)) == "Summarising…")
        #expect(AppleEngine.statusVerb(for: "explain this") == "Reading…")
    }

    @Test func ollamaRefusesToolsAndMissingImages() async {
        let engine = OllamaEngine()
        let agent = await collect(engine.agent(request: "x", selection: .none))
        guard case .failed(.other(let reason)) = agent.first else { Issue.record("expected .failed(.other)"); return }
        #expect(reason == "Tools run on Apple's model.")
        let describe = await collect(engine.describeImage(question: "x", selection: Selection(kind: .text, text: "no image")))
        guard case .failed(.other) = describe.first else { Issue.record("expected .failed(.other)"); return }
    }
}

// MARK: - Measured on the runner

struct RunnerMeasurementTests {
    @Test func appleIntelligenceStatusOnTheRunner() {
        let status = AppleIntelligenceStatus.current
        switch status {
        case .ready:
            EngineMeasurements.note("Apple Intelligence: ready")
        case .unavailable(let reason):
            EngineMeasurements.note("Apple Intelligence: unavailable — \(reason)")
            #expect(reason.hasSuffix("."))
            #expect(reason.count > 20)
        }
    }

    @Test func appleEngineFailsFastWhenTheModelIsUnavailable() async {
        guard case .unavailable(let reason) = AppleIntelligenceStatus.current else {
            EngineMeasurements.note("AppleEngine.transform: skipped, the model is available here")
            return
        }
        let start = Date()
        let events = await collect(AppleEngine().transform(prompt: Prompts.prompt(for: .fix), selection: Selection(kind: .text, text: "teh cat")))
        let elapsed = Date().timeIntervalSince(start)
        EngineMeasurements.note("AppleEngine.transform while unavailable: \(events.count) event(s) in \(Int(elapsed * 1000)) ms")
        #expect(events.count == 1)
        guard case .failed(.unavailable(let message)) = events.first else { Issue.record("expected .failed(.unavailable)"); return }
        #expect(message == reason)
        let extract = await collect(AppleEngine().extract(prompt: "dates", selection: Selection(kind: .text, text: "Friday"), asCSV: false))
        guard case .failed(.unavailable) = extract.first else { Issue.record("expected .failed(.unavailable)"); return }
        let agent = await collect(AppleEngine().agent(request: "remind me", selection: .none))
        guard case .failed(.unavailable) = agent.first else { Issue.record("expected .failed(.unavailable)"); return }
    }

    @Test func describeImageWithoutTheImagePathFailsWithTheSentence() async {
        #if SDK_MACOS27
        if #available(macOS 27, *) {
            EngineMeasurements.note("describeImage: image path compiled in (SDK_MACOS27, macOS 27)")
            return
        }
        #endif
        let image = ImageScaling.solidColour(width: 16, height: 16, red: 1, green: 0, blue: 0).flatMap { ImageScaling.payload(from: $0) }
        let events = await collect(AppleEngine().describeImage(question: "", selection: Selection(kind: .image, image: image)))
        guard case .failed(.unavailable(let message)) = events.first else { Issue.record("expected .failed(.unavailable)"); return }
        #expect(message == "Apple's model takes images on macOS 27 and a build with the macOS 27 SDK.")
    }

    @Test func ollamaIsNotRunningOnTheRunner() async {
        let defaults = UserDefaults(suiteName: "EngineTests.ollama")!
        defaults.removePersistentDomain(forName: "EngineTests.ollama")
        // A port nothing listens on, so the result is the same with or without Ollama.
        defaults.set("http://127.0.0.1:1", forKey: SettingsKey.ollamaHost)
        let engine = OllamaEngine(suiteName: "EngineTests.ollama")
        let start = Date()
        let status = await engine.status()
        let elapsed = Date().timeIntervalSince(start)
        EngineMeasurements.note("Ollama status at 127.0.0.1:1: \(status) in \(Int(elapsed * 1000)) ms")
        #expect(status == .unavailable("Ollama isn't running at http://127.0.0.1:1."))
        #expect(elapsed < 5)
        let events = await collect(engine.transform(prompt: "Fix", selection: Selection(kind: .text, text: "x")))
        guard case .status = events.first else { Issue.record("expected a status first"); return }
        guard case .failed(.offline(let message)) = events.last else { Issue.record("expected .failed(.offline)"); return }
        #expect(message.hasPrefix("Ollama"))
    }

    @Test func theProbeFinishesQuicklyWithoutTheModel() async {
        let start = Date()
        let diagnostics = await EngineProbe.measure(force: true)
        let elapsed = Date().timeIntervalSince(start)
        EngineMeasurements.note("EngineProbe.measure: \(Int(elapsed * 1000)) ms; apple=\(diagnostics.apple); contextSize=\(diagnostics.contextSize.map { String($0) } ?? "nil"); variant=\(diagnostics.variant ?? "nil"); imageInput=\(diagnostics.imageInput); languages=\(diagnostics.supportedLanguages.count); ollama=\(diagnostics.ollama); visionModel=\(diagnostics.ollamaVisionModel ?? "nil")")
        #expect(elapsed < 15)
        #expect(diagnostics.measuredAt != nil)
        if diagnostics.apple == .ready {
            EngineMeasurements.note("EngineProbe: the model is available here, imageInput = \(diagnostics.imageInput)")
        } else {
            #if SDK_MACOS27
            if #available(macOS 27, *) {
                #expect(diagnostics.imageInput == .untested)
            } else {
                #expect(diagnostics.imageInput == .unsupported("Apple's model takes images on macOS 27."))
            }
            #else
            #expect(diagnostics.imageInput == .notInThisBuild)
            #endif
        }
        // The second call is the cached one.
        let again = await EngineProbe.measure()
        #expect(again.measuredAt == diagnostics.measuredAt)
    }

    @Test func timeoutWins() async {
        do {
            _ = try await withTimeout(seconds: 0.05) { try await Task.sleep(for: .seconds(5)); return 1 }
            Issue.record("expected a timeout")
        } catch {
            #expect(error is TimeoutError)
        }
        let value = try? await withTimeout(seconds: 5) { 2 }
        #expect(value == 2)
    }

    #if SDK_MACOS27
    /// Compile-only proof that the Attachment path builds with the macOS 27 SDK.
    @Test func attachmentPathCompiles() {
        if #available(macOS 27, *) {
            let describe: (String, CGImage) async throws -> ImageDescription = AppleEngine.describeWithAttachment
            let probe: (CGImage) async throws -> String = AppleEngine.probeImageInput
            _ = (describe, probe)
            EngineMeasurements.note("Attachment path: compiled (SDK_MACOS27)")
        }
    }
    #endif
}
