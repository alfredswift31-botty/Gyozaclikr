import AppKit
import SwiftUI
import Testing
@testable import Gyozaclikr

// MARK: - Placement

struct BoxPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 360, height: 160)

    @Test func sitsEightPointsBelowTheSelection() {
        let anchor = CGRect(x: 420, y: 512, width: 560, height: 54)
        let frame = BoxPlacement.frame(size: size, anchor: .selection(anchor), screenVisible: screen)
        #expect(frame.minX == 420)
        #expect(frame.maxY == 504)
        #expect(!frame.intersects(anchor))
    }

    @Test func flipsAboveAtTheBottomEdge() {
        let anchor = CGRect(x: 100, y: 40, width: 300, height: 20)
        let placed = BoxPlacement.place(size: size, anchor: .selection(anchor), screenVisible: screen)
        #expect(placed.above)
        #expect(placed.frame.minY == 68)
        #expect(!placed.frame.intersects(anchor))
    }

    @Test func shiftsInsideAtTheRightEdge() {
        let anchor = CGRect(x: 1300, y: 500, width: 100, height: 20)
        let frame = BoxPlacement.frame(size: size, anchor: .selection(anchor), screenVisible: screen)
        #expect(frame.maxX == 1424)
        #expect(frame.minX >= 16)
        #expect(!frame.intersects(anchor))
    }

    @Test func pointerAnchorIsBelowRight() {
        let frame = BoxPlacement.frame(size: size, anchor: .pointer(CGPoint(x: 600, y: 400)), screenVisible: screen)
        #expect(frame.minX == 612)
        #expect(frame.maxY == 388)
    }

    @Test func regionAnchorsAtItsBottomLeft() {
        let region = CGRect(x: 300, y: 400, width: 320, height: 120)
        let frame = BoxPlacement.frame(size: size, anchor: .region(region), screenVisible: screen)
        #expect(frame.minX == 300)
        #expect(frame.maxY == 392)
    }

    @Test func neverCoversTheAnchor() {
        for x in stride(from: 0, through: 1400, by: 175) {
            for y in stride(from: 0, through: 860, by: 86) {
                let anchor = CGRect(x: CGFloat(x), y: CGFloat(y), width: 200, height: 30)
                let frame = BoxPlacement.frame(size: size, anchor: .selection(anchor), screenVisible: screen)
                #expect(!frame.intersects(anchor), "anchor \(anchor) got \(frame)")
                #expect(frame.minX >= 16 && frame.maxX <= 1424 && frame.minY >= 16 && frame.maxY <= 859)
            }
        }
    }

    @Test func staysOnAScreenAboveThePrimary() {
        let upper = CGRect(x: -200, y: 900, width: 1920, height: 1055)
        let anchor = CGRect(x: 1600, y: 920, width: 200, height: 20)
        let placed = BoxPlacement.place(size: size, anchor: .selection(anchor), screenVisible: upper)
        #expect(placed.above)
        #expect(upper.insetBy(dx: 15, dy: 15).contains(placed.frame))
    }

    @MainActor @Test func distancesMatchTheTheme() {
        #expect(BoxPlacement.anchorGap == Theme.Box.anchorGap)
        #expect(BoxPlacement.pointerOffset == Theme.Box.pointerOffset)
        #expect(BoxPlacement.screenInset == Theme.Box.screenInset)
    }
}

// MARK: - Markdown

struct MarkdownLiteTests {
    @Test func boldRunsInsideAParagraph() {
        let blocks = MarkdownLite.parse("Send the **numbers** by Friday.")
        #expect(blocks == [.paragraph([.text("Send the "), .bold("numbers"), .text(" by Friday.")])])
    }

    @Test func nestedBullets() {
        let blocks = MarkdownLite.parse("- Review the doc\n  - Finance closes after\n- Book a slot")
        guard case .bullets(let items)? = blocks.first else { Issue.record("not a list: \(blocks)"); return }
        #expect(items.map(\.depth) == [0, 1, 0])
        #expect(items[1].inlines == [.text("Finance closes after")])
    }

    @Test func numberedList() {
        let blocks = MarkdownLite.parse("1. Reply to Dana\n2. Block the slot")
        guard case .numbered(let items)? = blocks.first else { Issue.record("not numbered: \(blocks)"); return }
        #expect(items.map(\.number) == [1, 2])
        #expect(items[0].inlines == [.text("Reply to Dana")])
    }

    @Test func fencedCodeKeepsItsLines() {
        let blocks = MarkdownLite.parse("Before\n```\nlet a = 1\nlet b = 2\n```\nAfter")
        #expect(blocks == [.paragraph([.text("Before")]), .code("let a = 1\nlet b = 2"), .paragraph([.text("After")])])
    }

    @Test func aStrayAsteriskStays() {
        #expect(MarkdownLite.inlines("5 * 3 = 15 and **unclosed") == [.text("5 * 3 = 15 and **unclosed")])
        #expect(MarkdownLite.inlines("a `b") == [.text("a `b")])
    }

    @Test func inlineCodeAndHeadingsWithoutHeadings() {
        #expect(MarkdownLite.inlines("run `make` now") == [.text("run "), .code("make"), .text(" now")])
        #expect(MarkdownLite.parse("## Title") == [.paragraph([.bold("Title")])])
    }

    @Test func lineCountIgnoresBlankLines() {
        #expect(MarkdownLite.lineCount("a\n\nb\nc\n") == 3)
        #expect(MarkdownLite.plainText("- **x** y\n\n`z`") == "• x y\n\nz")
    }
}

// MARK: - Chips, rows, lines

struct ChipFilterTests {
    @Test func theLastWordNarrowsTheRow() {
        #expect(ChipFilter.visible(Chip.allCases, input: "make this fo") == [.formal])
        #expect(ChipFilter.visible(Chip.allCases, input: "make this") == Chip.allCases)
        #expect(ChipFilter.visible(Chip.allCases, input: "") == Chip.allCases)
        #expect(ChipFilter.suggestion(Chip.allCases, input: "sum", preferred: .fix) == .summarise)
        #expect(ChipFilter.suggestion(Chip.allCases, input: "", preferred: .fix) == .fix)
        #expect(ChipFilter.suggestion(Chip.allCases, input: "hello", preferred: .fix) == nil)
    }
}

struct ConfirmationRowsTests {
    @Test func mailListsEveryArgument() {
        let rows = ConfirmationRows.rows(for: .sendMail(to: ["dana@example.com"], subject: "Q4", body: "line one\nline two\nline three"))
        #expect(rows.map(\.label) == ["To", "Subject", "Body"])
        #expect(rows[0].value == "dana@example.com")
        #expect(rows[2].lines == 2)
        #expect(ConfirmationRows.verb(for: .sendMail(to: [], subject: "", body: "")) == "Send")
    }

    @Test func datesReadInWords() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 9; components.hour = 9; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(ConfirmationRows.format(date, timeZone: TimeZone(identifier: "UTC")!) == "Fri 9 Oct, 09:00")
        let rows = ConfirmationRows.rows(for: .createReminder(title: "Send numbers", due: nil, dueText: "friday 9am"))
        #expect(rows[1].value == "friday 9am")
    }
}

@MainActor
struct EngineLinesTests {
    @Test func appleLinesSayWhatWasMeasured() {
        let lines = EngineLines.apple(UIFixtures.diagnostics)
        #expect(lines == ["status: ready", "context: 4096 tokens", "variant: 27.0 · 3B", "image input: supported", "languages: 12"])
        #expect(EngineLines.apple(UIFixtures.diagnosticsOffline)[3] == "image input: not in this build")
        #expect(EngineLines.ollama(UIFixtures.diagnosticsOffline) == ["status: Ollama is not running."])
        #expect(EngineLines.ollama(UIFixtures.diagnostics) == ["status: reachable · 3 models · vision: qwen3-vl:8b"])
    }

    @Test func shortcutText() {
        #expect(HotKeyText.describe(keyCode: HotKeyText.defaultKeyCode, carbonModifiers: HotKeyText.defaultModifiers) == "⌃Space")
        #expect(HotKeyText.describe(keyCode: 0, carbonModifiers: HotKeyText.carbonModifiers(from: [.command, .shift])) == "⇧⌘A")
    }
}

@MainActor
struct StatusMenuTests {
    @Test func dotOnlyWhenAPermissionIsMissing() {
        #expect(UIFixtures.menuModel().missingPermission)
        var all = UIFixtures.menuModel()
        all.permissions = UIFixtures.allGranted
        #expect(!all.missingPermission)
        let items = UIFixtures.menuModel().items
        #expect(items.map(\.title) == ["Open Gyozaclikr", "Last answer…", "History…", "", "Engines", "Permissions", "", "Settings…", "Quit Gyozaclikr"])
        let permissions = items.first { $0.kind == .permissions }?.children ?? []
        #expect(permissions.map(\.dotted) == [true, false, true, false, false])
        #expect(permissions[1].title == "Screen Recording · Grant…")
        #expect(UIFixtures.menuModel().engineLines == ["Apple Intelligence · ready", "Ollama · reachable · qwen3-vl:8b"])
    }
}

// MARK: - The model

@MainActor
struct BoxModelTests {
    @Test func twoTokensWithinTheWindowFlushOnce() async throws {
        let coalescer = TokenCoalescer(window: 0.04)
        var flushes: [String] = []
        coalescer.onFlush = { flushes.append($0) }
        coalescer.append("Hel")
        coalescer.append("lo")
        #expect(flushes.isEmpty)
        // A loaded runner can delay the 40 ms timer well past it: wait up to a second.
        for _ in 0..<40 where flushes.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(flushes == ["Hello"])
        #expect(coalescer.flushCount == 1)
        coalescer.append(" there")
        coalescer.flushNow()
        #expect(flushes == ["Hello", " there"])
    }

    @Test func statesFollowTheCoordinator() {
        let model = BoxModel()
        var closed = 0, cancelled = 0
        var actions: [ResultAction] = []
        model.onClose = { closed += 1 }
        model.onCancel = { cancelled += 1 }
        model.onAction = { actions.append($0) }
        model.present(UIFixtures.textSelection, chips: Chip.allCases, suggested: .fix)
        #expect(model.state == .empty)
        #expect(model.width == 360)
        #expect(model.activeSuggestion == .fix)
        model.inputChanged("make this fo")
        #expect(model.state == .typing)
        #expect(model.visibleChips == [.formal])
        #expect(model.activeSuggestion == .formal)
        model.escape()
        #expect(closed == 1)
        model.begin(status: "Rewriting…", engine: .apple, request: "Formal")
        #expect(model.state == .streaming)
        #expect(model.width == 480)
        model.escape()
        #expect(cancelled == 1 && closed == 1)
        model.finish(Answer(text: UIFixtures.formalAnswer, engine: .apple))
        #expect(model.state == .done)
        #expect(model.primaryAction == .replace)
        model.primary()
        #expect(actions == [.replace])
        #expect(model.engineLabel == "Apple Intelligence · on-device")
        model.engine = .ollama
        model.engineModelName = "Qwen3-VL-8B"
        #expect(model.engineLabel == "Ollama · Qwen3-VL-8B · on this Mac")
        #expect(model.accessibilityTitle == "Gyozaclikr, selection of 412 tokens")
    }

    @Test func editPutsTheProposalBackInTheInput() {
        let model = BoxModel()
        model.present(UIFixtures.readOnlySelection, chips: Chip.allCases, suggested: nil)
        #expect(model.primaryAction == .copy)
        #expect(model.actions == [.copy, .send])
        model.confirm(.sendMail(to: ["dana@example.com"], subject: "Q4", body: "x"))
        #expect(model.state == .confirming)
        model.edit()
        #expect(model.state == .typing)
        #expect(model.input == "send this to dana@example.com · Q4")
    }
}

// MARK: - Snapshots

/// Every state of the box, the three Settings panes that carry facts, the
/// menu and About, light and dark. CI prints the PNGs; the integrator
/// reviews them against docs/DESIGN.md.
@MainActor
@Suite(.serialized)
struct UISnapshotTests {
    /// The card on a canvas, opaque: off screen there is no window behind the material.
    private static func sheet(_ model: BoxModel) -> some View {
        BoxView(model: model)
            .environment(\.boxOpaque, true)
            .environment(\.boxAnimates, true)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
    }

    private static func box(_ model: BoxModel, name: String, height: CGFloat, dark: Bool) throws {
        try Snapshot.render(sheet(model), name: name, size: CGSize(width: model.width, height: height), dark: dark)
    }

    @Test(arguments: [false, true])
    func boxThread(dark: Bool) throws {
        let model = UIFixtures.model(.done)
        model.begin(status: "Rewriting…", engine: .apple, request: "shorter")
        model.finish(Answer(text: "Dana, could you send the hardware numbers by Friday so Finance can close the forecast?", engine: .apple))
        try Self.box(model, name: "15-box-thread", height: 420, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxEmptyText(dark: Bool) throws {
        try Self.box(UIFixtures.model(.empty), name: "01-box-empty-text", height: 184, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxEmptyImage(dark: Bool) throws {
        try Self.box(UIFixtures.model(.empty, selection: UIFixtures.imageSelection), name: "02-box-empty-image", height: 192, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxTyping(dark: Bool) throws {
        try Self.box(UIFixtures.model(.typing), name: "03-box-typing", height: 152, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxStreaming(dark: Bool) throws {
        try Self.box(UIFixtures.model(.streaming), name: "04-box-streaming", height: 248, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxDone(dark: Bool) throws {
        try Self.box(UIFixtures.model(.done), name: "05-box-done", height: 312, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxFailed(dark: Bool) throws {
        try Self.box(UIFixtures.model(.failed), name: "06-box-failed", height: 168, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxConfirm(dark: Bool) throws {
        try Self.box(UIFixtures.model(.confirming), name: "07-box-confirm", height: 248, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxOllama(dark: Bool) throws {
        try Self.box(UIFixtures.ollamaModel(), name: "08-box-ollama", height: 240, dark: dark)
    }

    @Test(arguments: [false, true])
    func boxAsking(dark: Bool) throws {
        try Self.box(UIFixtures.model(.asking), name: "09-box-asking", height: 208, dark: dark)
    }

    @Test(arguments: [false, true])
    func settingsEngines(dark: Bool) throws {
        let height: CGFloat = 640
        try Snapshot.render(SettingsView(model: UIFixtures.settingsModel(), tab: .engines, height: height),
                            name: "10-settings-engines", size: CGSize(width: Theme.Settings.width, height: height), dark: dark)
    }

    @Test(arguments: [false, true])
    func settingsPermissions(dark: Bool) throws {
        let height: CGFloat = 560
        try Snapshot.render(SettingsView(model: UIFixtures.settingsModel(), tab: .permissions, height: height),
                            name: "11-settings-permissions", size: CGSize(width: Theme.Settings.width, height: height), dark: dark)
    }

    @Test(arguments: [false, true])
    func statusMenu(dark: Bool) throws {
        let sheet = StatusMenuView(model: UIFixtures.menuModel())
            .frame(width: 288)
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        try Snapshot.render(sheet, name: "12-status-menu", size: CGSize(width: 320, height: 520), dark: dark)
    }

    @Test(arguments: [false, true])
    func about(dark: Bool) throws {
        let height: CGFloat = 400
        try Snapshot.render(SettingsView(model: UIFixtures.settingsModel(), tab: .about, height: height),
                            name: "13-about", size: CGSize(width: Theme.Settings.width, height: height), dark: dark)
    }
}

@MainActor
struct PointerCompanionTests {
    @Test func theGyozaSitsBelowRightOfThePointer() {
        let origin = PointerCompanion.origin(forPointer: CGPoint(x: 100, y: 500))
        #expect(origin.x == 114)
        #expect(origin.y == 500 - 26 - PointerCompanion.size / 2)
    }

    @Test(arguments: [false, true])
    func companion(dark: Bool) throws {
        let sheet = HStack(spacing: 24) {
            PointerCompanionView()
            PointerCompanionView().scaleEffect(4).frame(width: 120, height: 120)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        try Snapshot.render(sheet, name: "14-pointer-gyoza", size: CGSize(width: 260, height: 180), dark: dark)
    }
}

@MainActor
struct ThreadTests {
    @Test func turnsStackAndTheFieldClears() {
        let model = UIFixtures.model(.empty)
        model.begin(status: "Working…", engine: .apple, request: "what is this")
        #expect(model.input.isEmpty)
        #expect(model.turns.count == 1)
        model.append(token: "An inv")
        model.finish(Answer(text: "An invoice.", engine: .apple))
        #expect(model.turns.last?.answer == "An invoice.")
        #expect(model.placeholder == "Ask a follow-up…")
        #expect(model.width == Theme.Box.wideWidth)
        model.begin(status: "Working…", engine: .ollama, request: "who issued it")
        model.fail(.refused)
        #expect(model.turns.count == 2)
        #expect(model.turns.last?.failure == EngineFailure.refused.message)
        model.present(UIFixtures.textSelection, chips: [], suggested: nil)
        #expect(model.turns.isEmpty)
    }

    @Test func followUpsCarryTheEarlierTurns() {
        var first = Turn(request: "what is this", engine: .apple); first.answer = "An invoice for 1,284."
        var failed = Turn(request: "who is this", engine: .apple); failed.failure = "I don't identify people."
        let prompt = Coordinator.contextualise("is it overdue?", turns: [first, failed])
        #expect(prompt.hasPrefix("Earlier in this conversation:\nUser: what is this\nAssistant: An invoice for 1,284."))
        #expect(prompt.contains("The user now asks: is it overdue?\nAnswer this new question; do not repeat an earlier answer."))
        #expect(!prompt.contains("who is this"), "failed turns carry nothing")
        #expect(Coordinator.contextualise("summarise", turns: []) == "summarise")
    }

    @Test func cornerDragResizesFromTheTopLeft() {
        let start = CGRect(x: 100, y: 500, width: 480, height: 300)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Right and down: wider and taller, same top-left.
        let bigger = BoxPanel.resized(from: start, by: CGSize(width: 120, height: -200), within: screen)
        #expect(bigger == CGRect(x: 100, y: 300, width: 600, height: 500))
        // Too far up and left: the minimum, still anchored top-left.
        let smallest = BoxPanel.resized(from: start, by: CGSize(width: -400, height: 400), within: screen)
        #expect(smallest.size == BoxModel.minSize)
        #expect(smallest.minX == 100 && smallest.maxY == 800)
        // Off the screen: clamped to its edges.
        let clamped = BoxPanel.resized(from: start, by: CGSize(width: 2000, height: -2000), within: screen)
        #expect(clamped.maxX == 1440 && clamped.minY == 0)
    }

    @Test func userSizeRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "GyozaclikrTests.boxSize")!
        defaults.removePersistentDomain(forName: "GyozaclikrTests.boxSize")
        #expect(BoxModel.savedSize(defaults) == nil)
        defaults.set(520.0, forKey: SettingsKey.boxWidth)
        defaults.set(400.0, forKey: SettingsKey.boxHeight)
        #expect(BoxModel.savedSize(defaults) == CGSize(width: 520, height: 400))
        defaults.set(0.0, forKey: SettingsKey.boxWidth)
        #expect(BoxModel.savedSize(defaults) == nil, "0 means automatic")
    }

    @Test func fenceMarksNeverReachTheAnswer() {
        #expect(BoxModel.unfenced("where road works are taking place.⟫") == "where road works are taking place.")
        #expect(BoxModel.unfenced("⟪quoted⟫ back") == "quoted back")
        #expect(BoxModel.unfenced("plain") == "plain")
        let model = UIFixtures.model(.empty)
        model.begin(status: "Working…", engine: .apple, request: "x")
        model.finish(Answer(text: "done.⟫", kind: .text, engine: .apple))
        #expect(model.answer == "done.")
        #expect(model.turns.last?.answer == "done.")
    }
}
