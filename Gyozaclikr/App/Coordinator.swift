import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI

/// The one object that knows every module: it turns a gesture into a
/// Selection, a Selection and a request into a Route, a Route into engine
/// events or an action, and shows all of it in the box. Modules never talk
/// to each other; they talk to this.
@Observable
final class Coordinator {
    // Capture
    let hotKey = HotKey()
    let selectionReader = SelectionReader()
    let regionCapture = RegionCapture()
    let services = ServicesProvider()
    let capturePermissions = CapturePermissions()
    // Engines
    private(set) var apple = AppleEngine()
    let ollama = OllamaEngine()
    // Router and actions
    let router = Router()
    let history = HistoryStore()
    let actionPermissions = ActionPermissions()
    private(set) var actions: ActionPerformer!
    // UI
    let model = BoxModel()
    private(set) var panel: BoxPanel!
    let statusItem = StatusItemController()
    let settingsModel = SettingsModel()
    let companion = PointerCompanion()
    private var defaultsObserver: NSObjectProtocol?

    private(set) var diagnostics = EngineDiagnostics()
    private(set) var permissions: [Permission: PermissionState] = [:]
    private var current: Task<Void, Never>?
    private var lastAnswer: Answer?
    private var lastSelection: Selection = .none
    private var lastRequest: Request?

    init() {
        actions = ActionPerformer { answer in AnswerWindow.show(answer: answer.text) }
        panel = BoxPanel(model: model)
        wireCallbacks()
        registerHotKey()
        services.register()
        refreshPermissions()
        refreshMenu()
        companion.setEnabled(Self.pointerGyozaWanted)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.companion.isEnabled != Self.pointerGyozaWanted else { return }
                self.companion.setEnabled(Self.pointerGyozaWanted)
            }
        }
        Task { await measureEngines() }
    }

    private static var pointerGyozaWanted: Bool {
        (UserDefaults.standard.object(forKey: SettingsKey.pointerGyoza) as? Bool) ?? true
    }

    // MARK: Summoning

    enum Mode { case selection, region, given(Selection) }

    func summon(_ mode: Mode) {
        current?.cancel()
        switch mode {
        case .region:
            panel.dismiss()
            companion.boxShown()
            Task { await captureRegion() }
        case .given(let selection):
            present(selection, anchor: .pointer(NSEvent.mouseLocation))
        case .selection:
            // Read before showing: once the box is key, the focused element
            // and a simulated ⌘C both land on the box itself (the first
            // TextEdit test read nothing). An AX read takes milliseconds.
            companion.boxShown()
            Task { await readThenPresent() }
        }
        Task { await apple.prewarm() }
    }

    private func present(_ selection: Selection, anchor: BoxAnchor) {
        lastSelection = selection
        lastAnswer = nil
        model.present(selection, chips: Self.chips(for: selection), suggested: Self.suggestedChip(for: selection))
        model.engine = preferredEngine(for: selection)
        companion.boxShown()
        panel.show(anchoredTo: anchor)
        recordBoxDiagnostics(after: "summon")
    }

    private static let log = Logger(subsystem: "com.gyoza.Gyozaclikr", category: "box")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 300 ms after a show: what the panel is doing, for the Engines pane
    /// and the unified log (`log show --predicate 'subsystem == "com.gyoza.Gyozaclikr"' --last 10m`).
    private func recordBoxDiagnostics(after event: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            let line = "\(event) \(Self.clock.string(from: Date())) · \(panel.diagnosticLine) · hotkey \(hotKey.isRegistered ? hotKey.displayString : "unregistered")"
            settingsModel.boxDiagnostics = line
            Self.log.notice("\(line, privacy: .public)")
        }
    }

    private func readThenPresent() async {
        let result = await selectionReader.readSelection()
        let pointer = NSEvent.mouseLocation
        switch result {
        case .success(let selection):
            present(selection, anchor: selection.bounds.map { .selection($0) } ?? .pointer(pointer))
        case .failure(.nothingSelected):
            if let word = await selectionReader.wordUnderPointer() {
                present(word, anchor: word.bounds.map { .selection($0) } ?? .pointer(pointer))
            } else {
                present(.none, anchor: .pointer(pointer))
            }
        case .failure(.accessibilityDenied):
            present(.none, anchor: .pointer(pointer))
            // The system dialog once per launch; afterwards the Privacy pane.
            let state = await request(.accessibility)
            model.fail(.other(state == .granted
                ? "Accessibility was just granted. Press the shortcut again."
                : "Accessibility isn't granted, so the selection can't be read. Turn on Gyozaclikr in System Settings › Privacy & Security › Accessibility, then press the shortcut again."))
        case .failure(let failure):
            present(.none, anchor: .pointer(pointer))
            model.fail(Self.failure(for: failure))
        }
    }

    private func captureRegion() async {
        switch await regionCapture.captureRegion() {
        case .success(let selection):
            present(selection, anchor: .region(selection.bounds ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)))
        case .failure(.cancelled):
            companion.boxHidden()
        case .failure(let failure):
            present(.none, anchor: .pointer(NSEvent.mouseLocation))
            model.fail(Self.failure(for: failure))
        }
    }

    private static func failure(for capture: CaptureFailure) -> EngineFailure {
        switch capture {
        case .accessibilityDenied: .other("Accessibility isn't granted, so the selection can't be read. Grant it in Settings › Permissions.")
        case .screenRecordingDenied: .other("Screen Recording isn't granted, or needs re-approval. Grant it in Settings › Permissions.")
        case .secureInput: .other("This field is in secure input (a password?), so nothing is read from it.")
        case .nothingSelected: .other("Nothing is selected.")
        case .cancelled: .cancelled
        case .other(let text): .other(text)
        }
    }

    // MARK: Chips and engines

    static func chips(for selection: Selection) -> [Chip] {
        switch selection.kind {
        case .text: Chip.allCases
        case .image: [.summarise, .list]
        case .word, .none: []
        }
    }

    /// A message gets Reply; everything else gets Fix.
    static func suggestedChip(for selection: Selection) -> Chip? {
        guard selection.kind == .text, let text = selection.text else { return nil }
        let lower = text.lowercased()
        let greeting = ["hi ", "hi,", "hello", "hey ", "dear "].contains { lower.hasPrefix($0) }
        let signoff = ["regards", "thanks", "cheers", "best,"].contains { lower.contains($0) }
        return greeting || signoff ? .reply : .fix
    }

    private func preferredEngine(for selection: Selection) -> EngineKind {
        if selection.kind == .image, !engineCapabilities[.apple, default: []].contains(.image),
           engineCapabilities[.ollama] != nil {
            return .ollama
        }
        return .apple
    }

    /// What the router may route to. When nothing is ready, Apple's engine
    /// stays in so it can report its own reason in the box.
    private var engineCapabilities: [EngineKind: Set<EngineCapability>] {
        var map: [EngineKind: Set<EngineCapability>] = [:]
        if case .ready = diagnostics.apple { map[.apple] = apple.capabilities }
        if case .ready = diagnostics.ollama { map[.ollama] = ollama.capabilities }
        if map.isEmpty { map[.apple] = apple.capabilities }
        return map
    }

    private func engine(_ kind: EngineKind) -> any LanguageEngine { kind == .apple ? apple : ollama }

    /// "change this", "make it formal", "summarise": a request about the
    /// selection rather than a standalone question.
    static func refersToSelection(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return [" this ", " it ", " these ", " the selection ", " the text ", " above ", "summarise", "summarize", "rewrite", "fix ", "shorter", "formal", "casual", "translate"]
            .contains { lower.contains($0) }
    }

    // MARK: Requests

    func submit(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "/history" { openHistory(); return }
        run(Request(selection: lastSelection, text: text))
    }

    func submit(chip: Chip) {
        run(Request(selection: lastSelection, chip: chip))
    }

    private func run(_ request: Request) {
        current?.cancel()
        lastRequest = request
        if !request.selection.hasContent, request.chip != nil || Self.refersToSelection(request.text) {
            model.fail(.other("Nothing was read from the screen, so there is nothing to \(request.chip?.title.lowercased() ?? "change"). Select text first, or grant Accessibility in Settings › Permissions."))
            return
        }
        let route = router.route(request, engines: engineCapabilities)
        current = Task { await execute(route, request: request) }
    }

    /// Earlier turns, so a follow-up ("shorter", "and in French?") reads
    /// as part of one conversation. Chips always act on the selection alone.
    static func contextualise(_ prompt: String, turns: [Turn], limit: Int = 2_000) -> String {
        let answered = turns.filter { !$0.answer.isEmpty && $0.failure == nil }.suffix(4)
        guard !answered.isEmpty else { return prompt }
        var lines: [String] = []
        for turn in answered {
            lines.append("User: " + turn.request)
            lines.append("Assistant: " + String(turn.answer.prefix(limit / answered.count)))
        }
        return "Earlier in this conversation:\n" + lines.joined(separator: "\n") + "\n\nThe user now asks: " + prompt
    }

    private func execute(_ route: Route, request: Request) async {
        let label = request.chip?.title ?? request.text
        let history = request.chip == nil ? model.turns : []
        switch route {
        case .transform(let prompt, let kind, let status):
            await stream(engine(kind).transform(prompt: Self.contextualise(prompt, turns: history), selection: request.selection), engine: kind, status: status, request: label)
        case .extract(let prompt, let kind):
            let lower = prompt.lowercased()
            let csv = lower.contains("csv") || lower.contains("table")
            await stream(engine(kind).extract(prompt: prompt, selection: request.selection, asCSV: csv), engine: kind, status: "Extracting…", request: label)
        case .describeImage(let question, let kind):
            await stream(engine(kind).describeImage(question: Self.contextualise(question, turns: history), selection: request.selection), engine: kind, status: "Looking…", request: label)
        case .perform(let proposal):
            await propose(proposal)
        case .composeThen(let prompt, let kind, let status, let target):
            await stream(engine(kind).transform(prompt: prompt, selection: request.selection), engine: kind, status: status, request: label)
            guard !Task.isCancelled, let answer = lastAnswer else { return }
            await propose(Self.proposal(for: target, text: answer.text, selection: request.selection))
        case .agent(let kind):
            await stream(engine(kind).agent(request: Self.contextualise(request.text, turns: history), selection: request.selection), engine: kind, status: "Working…", request: label)
        case .define(let word):
            if let definition = actions.define(word) {
                model.begin(status: "", engine: .apple, request: label)
                finish(Answer(text: definition, kind: .text, engine: .apple))
            } else {
                model.fail(.other("No definition for “\(word)”."))
            }
        case .refuse(let reason):
            model.fail(.other(reason))
        }
    }

    private func stream(_ events: AsyncStream<AnswerEvent>, engine kind: EngineKind, status: String, request: String) async {
        model.begin(status: status, engine: kind, request: request)
        await label(engine: kind)
        lastAnswer = nil
        let started = Date()
        for await event in events {
            if Task.isCancelled { model.fail(.cancelled); return }
            model.elapsed = Date().timeIntervalSince(started)
            switch event {
            case .status(let text): model.status = text
            case .token(let text): model.append(token: text)
            case .done(let answer): finish(answer)
            case .failed(let failure): model.fail(failure)
            case .needsConfirmation(let proposal): await propose(proposal)
            case .askUser(let question, let options): model.ask(question, options: options)
            }
        }
    }

    /// The collapsed engine row: Apple's model by name, or Ollama's model and host.
    private func label(engine kind: EngineKind) async {
        switch kind {
        case .apple:
            model.engineModelName = nil
            model.engineLeavesMac = false
        case .ollama:
            model.engineLeavesMac = !OllamaRequest.isLocal(ollama.host)
            model.engineModelName = await ollama.model(vision: lastSelection.kind == .image)
        }
    }

    private func finish(_ answer: Answer) {
        lastAnswer = answer
        model.finish(answer)
        history.append(HistoryEntry(date: Date(), requestText: model.lastRequest, chip: lastRequest?.chip?.rawValue,
                                    selectionPreview: String((lastSelection.text ?? "").prefix(120)),
                                    answerText: answer.text, engine: answer.engine.rawValue))
        settingsModel.history = history.entries
        refreshMenu()
        statusItem.nudge()
    }

    private func propose(_ proposal: ActionProposal) async {
        if proposal.needsConfirmation {
            model.confirm(proposal)
        } else {
            model.show(outcome: await actions.perform(proposal))
            if model.state == .streaming || model.state == .empty { model.state = .done }
        }
    }

    private static func proposal(for target: ComposeTarget, text: String, selection: Selection) -> ActionProposal {
        let title = SelectionText.title(selection.text ?? text)
        switch target {
        case .mail(let to, let subject): return .sendMail(to: to, subject: subject ?? title, body: text)
        case .note(let noteTitle): return .saveNote(title: noteTitle ?? title, body: text)
        case .reminder(let dueText): return .createReminder(title: text, due: nil, dueText: dueText)
        case .event(let whenText): return .createEvent(title: text, start: nil, end: nil, location: nil, whenText: whenText)
        }
    }

    // MARK: Callbacks

    private func wireCallbacks() {
        hotKey.onTap = { [weak self] in self?.summon(.selection) }
        hotKey.onHold = { [weak self] in self?.summon(.region) }
        services.onSelection = { [weak self] selection in self?.summon(.given(selection)) }

        model.onSubmit = { [weak self] text in self?.submit(text: text) }
        model.onChip = { [weak self] chip in self?.submit(chip: chip) }
        model.onAction = { [weak self] action in
            guard let self, let answer = lastAnswer else { return }
            Task { self.model.show(outcome: await self.actions.perform(action, answer: answer, selection: self.lastSelection)) }
        }
        model.onConfirm = { [weak self] proposal in
            guard let self else { return }
            Task {
                let outcome = await self.actions.perform(proposal)
                self.model.state = .done
                self.model.show(outcome: outcome)
            }
        }
        model.onOption = { [weak self] option in
            guard let self else { return }
            submit(text: model.lastRequest + " " + option)
        }
        model.onCancel = { [weak self] in self?.current?.cancel() }
        model.onClose = { [weak self] in
            self?.current?.cancel()
            self?.panel.dismiss()
            self?.companion.boxHidden()
        }
        model.onOpenHistory = { [weak self] in self?.openHistory() }

        statusItem.onOpen = { [weak self] in self?.summon(.selection) }
        statusItem.onLastAnswer = { [weak self] in
            if let answer = self?.lastAnswer { AnswerWindow.show(answer: answer.text) }
        }
        statusItem.onHistory = { [weak self] in self?.openHistory() }
        statusItem.onGrant = { [weak self] permission in Task { await self?.request(permission) } }
        statusItem.onSettings = { [weak self] in self?.openSettings() }

        settingsModel.onRecordShortcut = { [weak self] keyCode, modifiers in
            guard let self else { return }
            hotKey.unregister()
            _ = hotKey.register(keyCode: keyCode, modifiers: modifiers)
            refreshMenu()
        }
        settingsModel.onMeasureAgain = { [weak self] in Task { await self?.measureEngines(force: true) } }
        settingsModel.onGrant = { [weak self] permission in Task { await self?.request(permission) } }
        settingsModel.onClearHistory = { [weak self] in
            self?.history.clear()
            self?.settingsModel.history = []
        }
        settingsModel.history = history.entries
    }

    func openSettings() {
        settingsModel.history = history.entries
        refreshPermissions()
        SettingsWindow.shared.show(model: settingsModel)
    }

    func openHistory() {
        settingsModel.history = history.entries
        HistoryWindow.show(model: settingsModel)
    }

    // MARK: Engines and permissions

    func measureEngines(force: Bool = false) async {
        diagnostics = await EngineProbe.measure(force: force)
        // The Apple engine's image capability is a fact measured at launch.
        apple = AppleEngine(imageSupport: diagnostics.imageInput)
        if case .ready = diagnostics.ollama { model.ollamaAvailable = true } else { model.ollamaAvailable = false }
        settingsModel.diagnostics = diagnostics
        refreshMenu()
    }

    func refreshPermissions() {
        for permission in Permission.allCases {
            permissions[permission] = reporter(for: permission).state(of: permission)
        }
        settingsModel.permissions = permissions
        refreshMenu()
    }

    @discardableResult
    func request(_ permission: Permission) async -> PermissionState {
        let state = await reporter(for: permission).request(permission)
        permissions[permission] = state
        settingsModel.permissions = permissions
        refreshMenu()
        return state
    }

    private func reporter(for permission: Permission) -> any PermissionReporting {
        switch permission {
        case .accessibility, .screenRecording: capturePermissions
        default: actionPermissions
        }
    }

    /// The saved combination, else the fallbacks: ⌃Space is also macOS's
    /// input-source switch when two keyboard languages are on, and a taken
    /// combination fails silently in Carbon.
    private func registerHotKey() {
        if hotKey.register() { return }
        for (code, modifiers) in [(HotKey.defaultKeyCode, UInt32(controlKey | optionKey)), (HotKey.defaultKeyCode, UInt32(shiftKey | cmdKey))]
        where hotKey.register(keyCode: code, modifiers: modifiers) {
            return
        }
    }

    private func refreshMenu() {
        settingsModel.shortcutText = hotKey.isRegistered ? hotKey.displayString : "\(hotKey.displayString) is taken: change it in Settings"
        settingsModel.hotKeyRegistered = hotKey.isRegistered
        statusItem.menuModel = StatusMenuModel(shortcutText: hotKey.displayString, diagnostics: diagnostics,
                                               permissions: permissions, hasLastAnswer: lastAnswer != nil)
    }
}
