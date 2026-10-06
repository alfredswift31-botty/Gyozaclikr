import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// What Settings shows and whom it tells. The coordinator owns one,
/// refreshes `diagnostics`, `permissions` and `history`, and answers the
/// callbacks. Fields bound to `UserDefaults` use the keys in `SettingsKey`.
@Observable
final class SettingsModel {
    var diagnostics = EngineDiagnostics()
    var permissions: [Permission: PermissionState] = [:]
    var history: [HistoryEntry] = []
    var shortcutText: String = HotKeyText.describe(keyCode: HotKeyText.defaultKeyCode, carbonModifiers: HotKeyText.defaultModifiers)
    /// False when the system holds the combination (Carbon refuses it silently).
    var hotKeyRegistered = true
    /// What the box did on the last summon, measured 300 ms after it, for the Engines pane.
    var boxDiagnostics: String = "no summon yet"
    let defaults: UserDefaults

    var onRecordShortcut: (_ keyCode: UInt32, _ carbonModifiers: UInt32) -> Void = { _, _ in }
    var onMeasureAgain: () -> Void = {}
    var onGrant: (Permission) -> Void = { _ in }
    var onClearHistory: () -> Void = {}
    /// Click on a history row: copies the answer by default.
    var onCopyAnswer: (HistoryEntry) -> Void = { entry in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.answerText, forType: .string)
    }
    /// Open at login through `SMAppService`; overridable for tests and previews.
    var readOpenAtLogin: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var writeOpenAtLogin: (Bool) -> Void = { on in
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Open at login: \(error.localizedDescription)")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records the shortcut: stores the keys and tells the coordinator.
    func record(keyCode: UInt32, carbonModifiers: UInt32) {
        defaults.set(Int(keyCode), forKey: SettingsKey.hotKeyCode)
        defaults.set(Int(carbonModifiers), forKey: SettingsKey.hotKeyModifiers)
        shortcutText = HotKeyText.describe(keyCode: keyCode, carbonModifiers: carbonModifiers)
        onRecordShortcut(keyCode, carbonModifiers)
    }
}

nonisolated enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General", engines = "Engines", permissions = "Permissions", history = "History", about = "About"
    var id: String { rawValue }
}

/// Settings: a grouped Form on the canvas, 520 pt wide, five tabs.
struct SettingsView: View {
    let model: SettingsModel
    @State private var tab: SettingsTab
    let height: CGFloat

    init(model: SettingsModel, tab: SettingsTab = .general, height: CGFloat = Theme.Settings.height) {
        self.model = model
        _tab = State(initialValue: tab)
        self.height = height
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            Form {
                switch tab {
                case .general: GeneralPane(model: model)
                case .engines: EnginesPane(model: model)
                case .permissions: PermissionsPane(model: model)
                case .history: HistoryPane(model: model)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.canvas)
        .frame(width: Theme.Settings.width, height: height)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: SettingsModel
    @State private var openAtLogin = false
    @AppStorage(SettingsKey.pillEnabled) private var pillEnabled = false
    @AppStorage(SettingsKey.pointerGyoza) private var pointerGyoza = true
    @AppStorage(SettingsKey.historyLimit) private var historyLimit = 50

    init(model: SettingsModel) {
        self.model = model
        _pillEnabled = AppStorage(wrappedValue: false, SettingsKey.pillEnabled, store: model.defaults)
        _pointerGyoza = AppStorage(wrappedValue: true, SettingsKey.pointerGyoza, store: model.defaults)
        _historyLimit = AppStorage(wrappedValue: 50, SettingsKey.historyLimit, store: model.defaults)
    }

    var body: some View {
        Section {
            LabeledContent("Shortcut") {
                ShortcutRecorder(text: model.shortcutText) { keyCode, modifiers in
                    model.record(keyCode: keyCode, carbonModifiers: modifiers)
                }
                .frame(width: 140)
            }
            Toggle("Show the olive gyoza beside the pointer", isOn: $pointerGyoza)
            Toggle("Show a pill after a drag selection", isOn: $pillEnabled)
                .disabled(true)
        } header: {
            Text("Summon").labelStyle()
        } footer: {
            Text(model.hotKeyRegistered
                 ? "Tap the shortcut for the current selection; hold it for a screen region. The pill arrives in 1.1."
                 : "macOS holds this combination (⌃Space switches keyboard languages when more than one is on). Record another one.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(model.hotKeyRegistered ? Theme.inkSecondary : Theme.live)
        }

        Section {
            Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { on in
                openAtLogin = on
                model.writeOpenAtLogin(on)
            }))
            Picker("Keep", selection: $historyLimit) {
                Text("20 requests").tag(20)
                Text("50 requests").tag(50)
                Text("200 requests").tag(200)
            }
        } header: {
            Text("General").labelStyle()
        } footer: {
            Text("History stays on this Mac. Nothing is sent anywhere unless you pick an engine that is not on it.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        }
        .onAppear { openAtLogin = model.readOpenAtLogin() }
    }
}

/// A text field that captures the next key combination pressed in it.
struct ShortcutRecorder: NSViewRepresentable {
    let text: String
    var onRecord: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.placeholderString = "Press keys"
        field.onRecord = onRecord
        field.setAccessibilityLabel("Shortcut")
        field.setAccessibilityHelp("Click, then press the keys to use.")
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.stringValue = field.isRecording ? "Press keys…" : text
        field.onRecord = onRecord
    }

    final class RecorderField: NSTextField {
        var onRecord: (UInt32, UInt32) -> Void = { _, _ in }
        private(set) var isRecording = false

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
            stringValue = "Press keys…"
        }

        override func becomeFirstResponder() -> Bool {
            isRecording = true
            stringValue = "Press keys…"
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }
            let modifiers = HotKeyText.carbonModifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // A bare letter would steal typing everywhere; function keys and modified keys are fine.
            let isFunctionKey = (Int(event.keyCode) >= kVK_F1 && Int(event.keyCode) <= kVK_F12) || event.keyCode == UInt16(kVK_F13)
            guard modifiers != 0 || isFunctionKey else { NSSound.beep(); return }
            isRecording = false
            onRecord(UInt32(event.keyCode), modifiers)
            window?.makeFirstResponder(nil)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
    }
}

// MARK: - Engines

/// The Engines pane in GyozaVitals' diagnostics style: mono lines of what
/// was measured, not assumed.
private struct EnginesPane: View {
    let model: SettingsModel
    @AppStorage(SettingsKey.ollamaHost) private var ollamaHost = "http://localhost:11434"
    @AppStorage(SettingsKey.ollamaVisionModel) private var ollamaModel = "qwen3-vl:8b"

    init(model: SettingsModel) {
        self.model = model
        _ollamaHost = AppStorage(wrappedValue: "http://localhost:11434", SettingsKey.ollamaHost, store: model.defaults)
        _ollamaModel = AppStorage(wrappedValue: "qwen3-vl:8b", SettingsKey.ollamaVisionModel, store: model.defaults)
    }

    var body: some View {
        Section {
            ForEach(EngineLines.apple(model.diagnostics), id: \.self) { DiagnosticsLine(text: $0) }
        } header: {
            Text("Apple Intelligence").labelStyle()
        } footer: {
            Text("The default engine. Text on macOS 26; text and images on macOS 27, where this Mac's tier allows it.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        }

        Section {
            TextField("Host", text: $ollamaHost)
                .font(Theme.Typeface.mono)
            TextField("Vision model", text: $ollamaModel)
                .font(Theme.Typeface.mono)
            ForEach(EngineLines.ollama(model.diagnostics), id: \.self) { DiagnosticsLine(text: $0) }
        } header: {
            Text("Ollama").labelStyle()
        } footer: {
            Text("The labelled second engine for image questions. A host that is not this Mac means the image leaves it; the box says so.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        }

        Section {
            HStack {
                DiagnosticsLine(text: EngineLines.measured(model.diagnostics))
                Spacer()
                Button("Measure again") { model.onMeasureAgain() }
            }
        }

        Section {
            DiagnosticsLine(text: "box: \(model.boxDiagnostics)")
        } header: {
            Text("Box").labelStyle()
        } footer: {
            Text("What the box did on the last press of the shortcut, 300 ms after it. Share this when the box does not appear.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

/// The mono lines of the Engines pane and the menu. Pure, tested.
nonisolated enum EngineLines {
    static let dash = "\u{2013}"

    static func apple(_ d: EngineDiagnostics) -> [String] {
        let status: String = switch d.apple {
        case .ready: "ready"
        case .unavailable(let why): "unavailable · \(why)"
        }
        let image: String = switch d.imageInput {
        case .supported: "supported"
        case .unsupported(let why): "unsupported · \(why)"
        case .notInThisBuild: "not in this build"
        case .untested: "untested"
        }
        return [
            "status: \(status)",
            "context: \(d.contextSize.map { "\($0) tokens" } ?? dash)",
            "variant: \(d.variant ?? dash)",
            "image input: \(image)",
            "languages: \(d.supportedLanguages.isEmpty ? dash : "\(d.supportedLanguages.count)")",
        ]
    }

    static func ollama(_ d: EngineDiagnostics) -> [String] {
        switch d.ollama {
        case .ready:
            let models = d.ollamaModels.isEmpty ? "no models" : "\(d.ollamaModels.count) \(d.ollamaModels.count == 1 ? "model" : "models")"
            return ["status: reachable · \(models) · vision: \(d.ollamaVisionModel ?? dash)"]
        case .unavailable(let why):
            return ["status: \(why)"]
        }
    }

    static func measured(_ d: EngineDiagnostics) -> String {
        guard let at = d.measuredAt else { return "measured: not yet" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm:ss"
        return "measured: \(formatter.string(from: at))"
    }
}

/// One mono line; wraps rather than truncates.
private struct DiagnosticsLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typeface.mono)
            .foregroundStyle(Theme.inkSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    let model: SettingsModel

    var body: some View {
        Section {
            ForEach(Permission.allCases, id: \.self) { permission in
                let state = model.permissions[permission] ?? .unknown
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title).font(Theme.Typeface.heading).foregroundStyle(Theme.ink)
                        Text(permission.consequence).font(Theme.Typeface.meta).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    Text(Self.word(state))
                        .font(Theme.Typeface.mono)
                        .foregroundStyle(state == .granted ? Theme.ink : Theme.inkTertiary)
                        .padding(.top, 2)
                    if state != .granted {
                        Button("Grant…") { model.onGrant(permission) }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Permissions").labelStyle()
        } footer: {
            Text("Each is asked for on first use. Screen Recording asks again monthly; that is macOS, not Gyozaclikr.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    static func word(_ state: PermissionState) -> String {
        switch state {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not asked"
        case .unknown: "unknown"
        }
    }
}

// MARK: - History

/// The last requests: date, request, engine. Click copies the answer.
struct HistoryPane: View {
    let model: SettingsModel

    var body: some View {
        Section {
            if model.history.isEmpty {
                Text("Nothing yet.").font(Theme.Typeface.meta).foregroundStyle(Theme.inkTertiary)
            }
            ForEach(model.history) { entry in
                Button {
                    model.onCopyAnswer(entry)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(Self.when(entry.date)).font(Theme.Typeface.mono).foregroundStyle(Theme.inkTertiary).frame(width: 92, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.chip ?? entry.requestText).font(Theme.Typeface.meta).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(entry.answerText).font(Theme.Typeface.meta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.engine).font(Theme.Typeface.mono).foregroundStyle(Theme.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Copies the answer")
            }
        } header: {
            Text("History").labelStyle()
        } footer: {
            HStack {
                Text("Click a row to copy its answer.").font(Theme.Typeface.meta).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button("Clear") { model.onClearHistory() }.disabled(model.history.isEmpty)
            }
        }
    }

    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - About

/// The icon, the name over its gradient (the second permitted use), the version.
struct AboutPane: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Gyozaclikr")
                        .font(Theme.Typeface.title)
                        .tracking(Theme.Typeface.titleTracking)
                        .foregroundStyle(Theme.ink)
                    Theme.engineGradient.frame(width: 96, height: 2)
                }
                Text("Version \(Self.version)")
                    .font(Theme.Typeface.mono)
                    .foregroundStyle(Theme.inkSecondary)
                Text("Select something, press the shortcut, ask. Apple's on-device model answers; nothing leaves this Mac unless you pick an engine that is not on it.")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Space.s)
        }
    }

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

#Preview("Engines") {
    SettingsView(model: UIFixtures.settingsModel(), tab: .engines)
}
