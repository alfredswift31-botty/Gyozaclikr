import AppKit
import Foundation
import Observation

/// The box's states (docs/DESIGN.md "States"). `hidden` is the panel
/// off screen; the rest are what the card shows.
nonisolated enum BoxState: Hashable, Sendable {
    case hidden, empty, typing, streaming, done, failed, confirming, asking

    /// The wide card: the answer is on screen.
    var isWide: Bool { self == .streaming || self == .done }
    var isWorking: Bool { self == .streaming }
}

/// Everything the card shows, in one observable object the coordinator
/// writes and the views read. The coordinator sets the callbacks; the box
/// never performs anything itself.
/// One exchange in the box: what was asked and what came back.
nonisolated struct Turn: Identifiable, Hashable, Sendable {
    let id: UUID
    var request: String
    var answer: String
    var engine: EngineKind
    /// The sentence shown when the turn failed instead of answering.
    var failure: String?

    init(request: String, engine: EngineKind) {
        id = UUID(); self.request = request; answer = ""; self.engine = engine
    }
}

@Observable
final class BoxModel {
    /// The conversation so far, oldest first; the last turn is the live one.
    private(set) var turns: [Turn] = []
    var state: BoxState = .hidden
    var selection: Selection = .none
    var input: String = ""
    /// The context-filtered chips the coordinator chose for this selection.
    var chips: [Chip] = Chip.allCases
    /// The chip Tab accepts when the input is empty (dim accent outline).
    var suggestedChip: Chip?
    var engine: EngineKind = .apple
    /// The Ollama model's name for the label ("Qwen3-VL-8B"); nil for Apple.
    var engineModelName: String?
    /// A non-localhost Ollama host: the label says so.
    var engineLeavesMac = false
    /// The status verb while working ("Rewriting…").
    var status: String = ""
    /// The streamed answer, flushed in 40 ms steps so the layout does not shake.
    private(set) var answer: String = ""
    var answerKind: Answer.Kind = .text
    var kept = 0
    var dropped = 0
    var failure: EngineFailure?
    /// The confirmation card's content.
    var proposal: ActionProposal?
    /// The asking state.
    var question: String = ""
    var options: [String] = []
    /// One toast line under the actions, cleared after 2.5 s.
    private(set) var outcome: ActionOutcome?
    /// ↑ recalls this.
    var lastRequest: String = ""
    /// Accessibility vouched for the field (a native text field or area whose selection is settable): Replace leads.
    var isEditableSource = false
    /// Text read from an app at all (not a region capture, not a word under the pointer): Replace is offered,
    /// by ⌘V when Accessibility cannot write, since the field keeps its focus and its selection under the box.
    var canWriteBack = false
    /// Ollama answers image questions too: offered under an Apple image answer.
    var ollamaAvailable = false
    /// Every engine's state, for the picker: a disabled row says why.
    var engineStatus: [EngineKind: EngineStatus] = [:]
    func isAvailable(_ kind: EngineKind) -> Bool {
        if case .ready = engineStatus[kind] { return true }
        return false
    }
    /// The picker: the engine for the next request, and the default from then on.
    var onChooseEngine: (EngineKind) -> Void = { _ in }
    func choose(engine kind: EngineKind) {
        engine = kind
        engineModelName = nil
        engineLeavesMac = kind.leavesMac
        onChooseEngine(kind)
    }
    /// The deeper read: the same question through `/local`.
    var offersOllama: Bool { state == .done && answerKind == .description && engine == .apple && ollamaAvailable }
    func askOllama() { onSubmit("/local " + lastRequest) }
    /// Seconds since the request started, shown in mono on the Ollama path.
    var elapsed: TimeInterval = 0

    // MARK: Callbacks the coordinator sets

    var onSubmit: (String) -> Void = { _ in }
    var onChip: (Chip) -> Void = { _ in }
    var onAction: (ResultAction) -> Void = { _ in }
    var onConfirm: (ActionProposal) -> Void = { _ in }
    /// Puts the proposal back in the input for editing (the model does the text; the coordinator may add to it).
    var onEdit: (ActionProposal) -> Void = { _ in }
    var onOption: (String) -> Void = { _ in }
    /// Esc while streaming.
    var onCancel: () -> Void = {}
    /// Esc otherwise, a click outside, ⌘-Tab away.
    var onClose: () -> Void = {}
    var onOpenHistory: () -> Void = {}

    @ObservationIgnored private let coalescer = TokenCoalescer(window: Theme.Box.coalesce)
    @ObservationIgnored private var outcomeTask: Task<Void, Never>?
    @ObservationIgnored private var announcedSentences = 0
    /// Where sentence announcements go; VoiceOver by default, a test's array otherwise.
    @ObservationIgnored var announce: (String) -> Void = { sentence in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: sentence, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    init() {
        coalescer.onFlush = { [weak self] text in self?.flushed(text) }
    }

    // MARK: Derived, for the views

    /// 360 pt, or 480 once the conversation has a turn.
    var width: CGFloat { state.isWide || !turns.isEmpty ? Theme.Box.wideWidth : Theme.Box.width }

    /// The size the user dragged the box to (the corner grip or an edge),
    /// kept across summons and launches; nil means the card sizes itself to
    /// its content. "Automatic size" in the ⋯ menu clears it.
    var userSize: CGSize? = BoxModel.savedSize() {
        didSet { Self.save(userSize) }
    }

    nonisolated static func savedSize(_ defaults: UserDefaults = .standard) -> CGSize? {
        let width = defaults.double(forKey: SettingsKey.boxWidth)
        let height = defaults.double(forKey: SettingsKey.boxHeight)
        return width >= Self.minSize.width && height >= Self.minSize.height ? CGSize(width: width, height: height) : nil
    }

    private nonisolated static func save(_ size: CGSize?, _ defaults: UserDefaults = .standard) {
        defaults.set(size?.width ?? 0, forKey: SettingsKey.boxWidth)
        defaults.set(size?.height ?? 0, forKey: SettingsKey.boxHeight)
    }

    /// Smaller than this and the field, a row of actions and one line of answer no longer fit.
    nonisolated static let minSize = CGSize(width: 280, height: 160)

    var placeholder: String {
        if !turns.isEmpty { return "Ask a follow-up…" }
        return switch selection.kind {
        case .image: "Ask about this image…"
        case .word: "Define \(selection.word ?? "this word")…"
        case .text, .none: "Ask about this selection…"
        }
    }

    /// The chips the row shows, narrowed by the word being typed.
    var visibleChips: [Chip] { ChipFilter.visible(chips, input: input) }

    /// The chip Tab accepts right now.
    var activeSuggestion: Chip? { ChipFilter.suggestion(chips, input: input, preferred: suggestedChip) }

    /// The collapsed row's text while streaming and done.
    var engineLabel: String {
        var label = engine.label
        if engine == .ollama, let engineModelName {
            label = "Ollama · \(engineModelName) · on this Mac"
        }
        if engine == .claude, let engineModelName {
            label = "Claude · \(engineModelName)"
        }
        if engineLeavesMac { label += " · leaves this Mac" }
        return label
    }

    /// Replace when the source can take it, Copy otherwise.
    var primaryAction: ResultAction { isEditableSource ? .replace : .copy }

    /// The row's buttons in order: Replace leads where Accessibility vouched
    /// for the field, follows Copy where only ⌘V can try, and is absent for
    /// a region capture or a word under the pointer.
    var actions: [ResultAction] {
        if isEditableSource { return [.replace, .copy, .insertBelow, .send] }
        if canWriteBack { return [.copy, .replace, .insertBelow, .send] }
        return [.copy, .send]
    }

    var answerLineCount: Int { MarkdownLite.lineCount(answer) }
    var offersNewWindow: Bool { answerLineCount > Theme.Box.linesBeforeWindow }

    /// "Gyozaclikr, selection of 412 tokens".
    var accessibilityTitle: String {
        switch selection.kind {
        case .text:
            if let tokens = selection.tokenEstimate { return "Gyozaclikr, selection of \(tokens) tokens" }
            return "Gyozaclikr, text selection"
        case .image:
            if let words = selection.ocrWordCount { return "Gyozaclikr, image with \(words) words" }
            return "Gyozaclikr, image selection"
        case .word: return "Gyozaclikr, define \(selection.word ?? "")"
        case .none: return "Gyozaclikr"
        }
    }

    /// The two chips under a failure sentence; none for a cancel.
    var failureChips: [(title: String, action: () -> Void)] {
        guard let failure else { return [] }
        switch failure {
        case .refused, .other:
            return [("Try Fix", { [weak self] in self?.onChip(.fix) }), ("Copy", { [weak self] in self?.onAction(.copy) })]
        case .tooLong:
            return [("Shorter", { [weak self] in self?.onChip(.shorter) }), ("Summarise", { [weak self] in self?.onChip(.summarise) })]
        case .unavailable, .rateLimited, .offline, .unsupportedLanguage:
            return [("Try again", { [weak self] in self?.resubmit() })]
        case .cancelled:
            return []
        }
    }

    // MARK: Transitions the coordinator calls

    /// A fresh box over `selection`: empty state, chips as given.
    func present(_ selection: Selection, chips: [Chip], suggested: Chip?) {
        coalescer.cancel()
        self.selection = selection
        self.chips = chips
        self.suggestedChip = suggested
        isEditableSource = selection.isEditable
        canWriteBack = selection.kind == .text && selection.sourceApp != nil
        turns = []
        input = ""
        answer = ""
        answerKind = .text
        kept = 0; dropped = 0
        failure = nil
        proposal = nil
        question = ""; options = []
        outcome = nil
        status = ""
        elapsed = 0
        announcedSentences = 0
        state = .empty
    }

    /// The request went out: collapse the chips, show the verb.
    func begin(status: String, engine: EngineKind, request: String) {
        coalescer.cancel()
        self.status = status
        self.engine = engine
        lastRequest = request
        // The request joins the thread; the field clears for the next one (↑ brings it back).
        turns.append(Turn(request: request, engine: engine))
        input = ""
        answer = ""
        failure = nil
        elapsed = 0
        announcedSentences = 0
        state = .streaming
    }

    /// One streamed token; shown within 40 ms with whatever follows it.
    func append(token: String) {
        coalescer.append(token)
    }

    /// Replace the answer at once (a chunk, a corrected text).
    func setAnswer(_ text: String) {
        coalescer.cancel()
        answer = Self.unfenced(text)
        syncLastTurn()
    }

    func finish(_ result: Answer) {
        coalescer.flushNow()
        answer = Self.unfenced(result.text)
        answerKind = result.kind
        engine = result.engine
        kept = result.kept
        dropped = result.dropped
        syncLastTurn()
        state = .done
    }

    /// The fence marks around the selection (`Prompts.wrap`) are the
    /// prompt's, never the answer's; the model echoed a closing one on the
    /// owner's Mac (an OCR explanation ending in ⟫).
    nonisolated static func unfenced(_ text: String) -> String {
        text.contains("⟪") || text.contains("⟫") ? text.replacingOccurrences(of: "⟪", with: "").replacingOccurrences(of: "⟫", with: "") : text
    }

    private func syncLastTurn() {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = answer
        turns[turns.count - 1].engine = engine
    }

    func fail(_ failure: EngineFailure) {
        coalescer.flushNow()
        self.failure = failure
        if let last = turns.indices.last, turns[last].answer.isEmpty {
            turns[last].failure = failure.message
        }
        state = .failed
    }

    func confirm(_ proposal: ActionProposal) {
        coalescer.flushNow()
        self.proposal = proposal
        state = .confirming
    }

    func ask(_ question: String, options: [String]) {
        coalescer.flushNow()
        self.question = question
        self.options = options
        state = .asking
    }

    /// The toast line; gone after 2.5 s.
    func show(outcome: ActionOutcome) {
        self.outcome = outcome
        outcomeTask?.cancel()
        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.outcome = nil
        }
    }

    func hide() {
        coalescer.cancel()
        state = .hidden
    }

    // MARK: Key handling the views call

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let chip = activeSuggestion { onChip(chip) }
            return
        }
        onSubmit(text)
    }

    func resubmit() {
        guard !lastRequest.isEmpty else { return }
        onSubmit(lastRequest)
    }

    func recall() {
        guard !lastRequest.isEmpty else { return }
        input = lastRequest
    }

    /// Tab: the suggested chip. Returns false when there is none, so Tab can move focus.
    @discardableResult
    func acceptSuggestion() -> Bool {
        guard let chip = activeSuggestion else { return false }
        onChip(chip)
        return true
    }

    /// ⌘1–⌘8.
    func chip(number: Int) {
        guard let chip = Chip.allCases.first(where: { $0.shortcut == number }), chips.contains(chip) else { return }
        onChip(chip)
    }

    /// Esc: cancel while working, close otherwise.
    func escape() {
        if state.isWorking { onCancel() } else { onClose() }
    }

    /// ⌘↩: the primary result action, or the confirmation card's action.
    func primary() {
        switch state {
        case .done: onAction(primaryAction)
        case .confirming: if let proposal { onConfirm(proposal) }
        default: submit()
        }
    }

    func edit() {
        guard let proposal else { return }
        input = ConfirmationRows.editText(for: proposal)
        state = .typing
        onEdit(proposal)
    }

    func inputChanged(_ text: String) {
        input = text
        if state == .empty, !text.isEmpty { state = .typing }
        if state == .typing, text.isEmpty { state = .empty }
    }

    // MARK: Private

    private func flushed(_ text: String) {
        answer += Self.unfenced(text)
        syncLastTurn()
        // A polite live region, one sentence at a time.
        let sentences = answer.split(whereSeparator: { ".!?".contains($0) })
        if sentences.count > announcedSentences + 1 {
            let newOnes = sentences.dropFirst(announcedSentences).dropLast()
            for sentence in newOnes { announce(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
            announcedSentences = sentences.count - 1
        }
    }
}

/// Buffers streamed tokens and flushes them together after a short
/// window (Theme.Box.coalesce), so each layout pass sees a few words, not
/// one. `flushNow` and `cancel` are for the end of a stream.
final class TokenCoalescer {
    let window: TimeInterval
    var onFlush: (String) -> Void = { _ in }
    private(set) var flushCount = 0
    private var buffer = ""
    private var timer: Task<Void, Never>?

    init(window: TimeInterval) {
        self.window = window
    }

    func append(_ token: String) {
        buffer += token
        guard timer == nil else { return }
        timer = Task { [weak self, window] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.flushNow()
        }
    }

    func flushNow() {
        timer?.cancel()
        timer = nil
        guard !buffer.isEmpty else { return }
        let text = buffer
        buffer = ""
        flushCount += 1
        onFlush(text)
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        buffer = ""
    }
}
