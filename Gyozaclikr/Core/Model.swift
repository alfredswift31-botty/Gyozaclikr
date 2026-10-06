import CoreGraphics
import Foundation

// The contract between Gyozaclikr's modules. Capture produces a Selection;
// the Router turns a Request into a Route; an Engine answers with a stream of
// AnswerEvents; Actions perform ActionProposals and ResultActions; the UI
// renders all of it. Everything here is a plain value and Sendable, so any
// module can hand it across actors. Read docs/PLAN.md §2 and docs/DESIGN.md.

// MARK: - What was selected

/// An image as a value: PNG bytes plus its point size, so it crosses actors.
nonisolated struct ImagePayload: Hashable, Sendable {
    let png: Data
    /// Size in points on the screen it came from.
    let pointSize: CGSize
    /// Backing scale of that screen (2 on Retina).
    let scale: CGFloat
}

/// The app a selection came from.
nonisolated struct SourceApp: Hashable, Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
}

/// What the user selected before summoning the box.
nonisolated struct Selection: Hashable, Sendable {
    enum Kind: String, Sendable { case text, image, word, none }

    var kind: Kind
    /// Selected text; for an image, the OCR text once Live Text has run.
    var text: String?
    var image: ImagePayload?
    /// The word under the pointer when nothing was selected.
    var word: String?
    /// Screen rectangle of the selection in AppKit coordinates (origin
    /// bottom-left of the primary display), when the source exposed it.
    var bounds: CGRect?
    var sourceApp: SourceApp?
    /// Whether Replace / Insert below can write back into the source.
    var isEditable: Bool
    /// Rough token count of `text` (the engine refines it).
    var tokenEstimate: Int?
    /// Word count of the OCR text, once known.
    var ocrWordCount: Int?

    static let none = Selection(kind: .none, isEditable: false)

    init(kind: Kind, text: String? = nil, image: ImagePayload? = nil, word: String? = nil, bounds: CGRect? = nil,
         sourceApp: SourceApp? = nil, isEditable: Bool = false, tokenEstimate: Int? = nil, ocrWordCount: Int? = nil) {
        self.kind = kind; self.text = text; self.image = image; self.word = word; self.bounds = bounds
        self.sourceApp = sourceApp; self.isEditable = isEditable; self.tokenEstimate = tokenEstimate; self.ocrWordCount = ocrWordCount
    }

    var hasContent: Bool { kind != .none }
}

/// Why a selection could not be read.
nonisolated enum CaptureFailure: Error, Hashable, Sendable {
    /// Accessibility not granted: the box opens, but only region capture and the Services entry work.
    case accessibilityDenied
    /// Screen Recording not granted, or the monthly re-approval is pending.
    case screenRecordingDenied
    /// A password field or a terminal in secure input: never read.
    case secureInput
    /// Nothing was selected and no word is under the pointer.
    case nothingSelected
    case cancelled
    case other(String)
}

// MARK: - What the user asked

/// The eight quick actions. Fixed, tested prompts; ⌘1–⌘8.
nonisolated enum Chip: String, CaseIterable, Hashable, Sendable {
    case fix, shorter, formal, casual, summarise, list, reply, remind

    var title: String {
        switch self {
        case .fix: "Fix"
        case .shorter: "Shorter"
        case .formal: "Formal"
        case .casual: "Casual"
        case .summarise: "Summarise"
        case .list: "List"
        case .reply: "Reply"
        case .remind: "Remind"
        }
    }

    /// The ⌘-number, 1-based.
    var shortcut: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The status word shown while the engine works ("Rewriting…").
    var statusVerb: String {
        switch self {
        case .fix, .shorter, .formal, .casual: "Rewriting…"
        case .summarise: "Summarising…"
        case .list: "Listing…"
        case .reply: "Drafting…"
        case .remind: "Reading…"
        }
    }
}

/// Which model answers. Apple is the default; Ollama is always labelled.
nonisolated enum EngineKind: String, CaseIterable, Hashable, Sendable {
    case apple, ollama

    /// The label in the collapsed chip row and on the answer.
    var label: String {
        switch self {
        case .apple: "Apple Intelligence · on-device"
        case .ollama: "Ollama · on this Mac"
        }
    }
}

/// One request from the box: a chip or free text, over a selection.
nonisolated struct Request: Hashable, Sendable {
    let selection: Selection
    /// The typed request; empty when a chip was used.
    let text: String
    let chip: Chip?
    /// A forced engine (`/local`, or the user's choice); nil means the router decides.
    let engine: EngineKind?

    init(selection: Selection, text: String = "", chip: Chip? = nil, engine: EngineKind? = nil) {
        self.selection = selection; self.text = text; self.chip = chip; self.engine = engine
    }
}

// MARK: - What the router decides

/// Something that leaves the box: always shown on a confirmation card first.
nonisolated enum ActionProposal: Hashable, Sendable {
    case sendMail(to: [String], subject: String, body: String)
    /// `due` parsed by the app from `dueText`; nil when no date was found.
    case createReminder(title: String, due: Date?, dueText: String?)
    case createEvent(title: String, start: Date?, end: Date?, location: String?, whenText: String?)
    case saveNote(title: String, body: String)
    case runShortcut(name: String, input: String)
    case openURL(URL)
    case search(query: String)

    /// Whether performing it needs a confirmation card.
    var needsConfirmation: Bool {
        switch self {
        case .openURL, .search: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .sendMail: "Send mail"
        case .createReminder: "Add reminder"
        case .createEvent: "Add event"
        case .saveNote: "Save to Notes"
        case .runShortcut: "Run Shortcut"
        case .openURL: "Open link"
        case .search: "Search"
        }
    }
}

/// How a request will be handled.
nonisolated enum Route: Hashable, Sendable {
    /// Ask an engine to produce text from the selection: a chip's fixed
    /// prompt or the user's free text. `status` is the verb shown meanwhile.
    case transform(prompt: String, engine: EngineKind, status: String)
    /// Extract structured items with quote verification (dates, amounts, action items, table rows).
    case extract(prompt: String, engine: EngineKind)
    /// Describe an image, or answer a question about it, with an engine that can see.
    case describeImage(question: String, engine: EngineKind)
    /// A connector that needs no model at all.
    case perform(ActionProposal)
    /// A connector whose text (a mail body, a note) the engine writes first;
    /// `make` is applied to the engine's answer by the controller.
    case composeThen(prompt: String, engine: EngineKind, status: String, proposal: ComposeTarget)
    /// A free-text request the pre-router could not place: the engine gets tools.
    case agent(engine: EngineKind)
    /// The system dictionary, no model.
    case define(word: String)
    /// Refused by design, with the sentence the box shows.
    case refuse(reason: String)
}

/// The connector a composed text goes to.
nonisolated enum ComposeTarget: Hashable, Sendable {
    case mail(to: [String], subject: String?)
    case note(title: String?)
    case reminder(dueText: String?)
    case event(whenText: String?)
}

// MARK: - What an engine says

/// The streamed answer. Engines emit `status` and `token`s, then exactly one
/// of `done`, `failed`, `needsConfirmation` or `askUser`.
nonisolated enum AnswerEvent: Sendable {
    case status(String)
    case token(String)
    case done(Answer)
    case failed(EngineFailure)
    case needsConfirmation(ActionProposal)
    /// The engine needs one thing from the user (a recipient, a date); rendered as chips.
    case askUser(question: String, options: [String])
}

nonisolated struct Answer: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case text, csv, extraction, description }
    var text: String
    var kind: Kind
    var engine: EngineKind
    /// Extraction: items dropped because their quote was not in the selection.
    var dropped: Int
    /// Extraction: items kept.
    var kept: Int
    init(text: String, kind: Kind = .text, engine: EngineKind, dropped: Int = 0, kept: Int = 0) {
        self.text = text; self.kind = kind; self.engine = engine; self.dropped = dropped; self.kept = kept
    }
}

/// Why an engine did not answer; each case has the sentence the box shows.
nonisolated enum EngineFailure: Error, Hashable, Sendable {
    /// Apple Intelligence off, device ineligible, model downloading (GyozaYap's messages).
    case unavailable(String)
    /// A guardrail refused the input or the output.
    case refused
    /// The selection does not fit; both numbers are shown.
    case tooLong(tokens: Int, limit: Int)
    case rateLimited
    case unsupportedLanguage
    /// Ollama not reachable, model missing, or a transport error.
    case offline(String)
    case cancelled
    case other(String)

    var message: String {
        switch self {
        case .unavailable(let text): text
        case .refused: "The on-device model won't handle this input."
        case .tooLong(let tokens, let limit): "Selection is \(tokens) tokens; the on-device model takes \(limit)."
        case .rateLimited: "Apple Intelligence is busy. Try again in a moment."
        case .unsupportedLanguage: "Apple Intelligence doesn't support this language yet."
        case .offline(let text): text
        case .cancelled: "Cancelled."
        case .other(let text): text
        }
    }
}

/// What an engine can do, so the router never asks for the impossible.
nonisolated enum EngineCapability: Hashable, Sendable { case text, image, structured, tools }

/// The engine's state for the Engines pane and the box's placeholder.
nonisolated enum EngineStatus: Hashable, Sendable {
    case ready
    case unavailable(String)
}

/// An engine: Apple's on-device model or Ollama. Implementations live in
/// Gyozaclikr/Engine. The controller picks one per Route.
nonisolated protocol LanguageEngine: Sendable {
    var kind: EngineKind { get }
    var capabilities: Set<EngineCapability> { get }
    func status() async -> EngineStatus
    /// Load the model while the user types; never throws.
    func prewarm() async
    /// Produce text from `prompt` over `selection` (the engine wraps the
    /// selection so it is never treated as instructions). Streams tokens.
    func transform(prompt: String, selection: Selection) -> AsyncStream<AnswerEvent>
    /// Extract items with quote verification; returns `.done` with an
    /// `.extraction` answer rendered as a list (or CSV when `asCSV`).
    func extract(prompt: String, selection: Selection, asCSV: Bool) -> AsyncStream<AnswerEvent>
    /// Describe or answer a question about `selection.image`. Only when
    /// `capabilities` contains `.image`; otherwise emits `.failed`.
    func describeImage(question: String, selection: Selection) -> AsyncStream<AnswerEvent>
    /// A request with the four tools; emits `.needsConfirmation`, `.askUser` or text.
    func agent(request: String, selection: Selection) -> AsyncStream<AnswerEvent>
}

// MARK: - Acting on the result

/// The buttons under an answer.
nonisolated enum ResultAction: String, CaseIterable, Hashable, Sendable {
    case replace, copy, insertBelow, send, openInWindow

    var title: String {
        switch self {
        case .replace: "Replace"
        case .copy: "Copy"
        case .insertBelow: "Insert below"
        case .send: "Send…"
        case .openInWindow: "Open in new window"
        }
    }
}

/// How an action went, for the toast line under the box.
nonisolated enum ActionOutcome: Hashable, Sendable {
    case done(String)
    case failed(String)
}

// MARK: - Permissions, diagnostics, history

nonisolated enum Permission: String, CaseIterable, Hashable, Sendable {
    case accessibility, screenRecording, reminders, calendar, automationNotes, contacts

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .automationNotes: "Notes"
        case .contacts: "Contacts"
        }
    }

    /// What stops working without it.
    var consequence: String {
        switch self {
        case .accessibility: "Reading and replacing selections in other apps."
        case .screenRecording: "Capturing a region of the screen."
        case .reminders: "Adding reminders."
        case .calendar: "Adding events."
        case .automationNotes: "Saving to Notes."
        case .contacts: "Mailing a person by name."
        }
    }
}

nonisolated enum PermissionState: Hashable, Sendable { case granted, denied, notDetermined, unknown }

/// Whether Apple's model takes an image on this Mac, measured once at launch.
nonisolated enum ImageSupport: Hashable, Sendable {
    case supported
    case unsupported(String)
    /// Built against the macOS 26 SDK: the image API is not in this binary.
    case notInThisBuild
    case untested
}

/// The Engines pane: one line of facts per engine, measured, not assumed.
nonisolated struct EngineDiagnostics: Hashable, Sendable {
    var apple: EngineStatus = .unavailable("Not checked yet.")
    var contextSize: Int?
    var variant: String?
    var imageInput: ImageSupport = .untested
    var supportedLanguages: [String] = []
    var ollama: EngineStatus = .unavailable("Not checked yet.")
    var ollamaModels: [String] = []
    var ollamaVisionModel: String?
    var measuredAt: Date?
}

/// One past request, kept on this Mac only.
nonisolated struct HistoryEntry: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var requestText: String
    var chip: String?
    var selectionPreview: String
    var answerText: String
    var engine: String
}

// MARK: - Settings keys shared by modules

nonisolated enum SettingsKey {
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let pillEnabled = "pillEnabled"
    /// The olive gyoza beside the pointer while the app runs. On by default.
    static let pointerGyoza = "pointerGyoza"
    static let ollamaHost = "ollamaHost"
    static let ollamaVisionModel = "ollamaVisionModel"
    static let ollamaTextModel = "ollamaTextModel"
    static let historyLimit = "historyLimit"
    static let openAtLogin = "openAtLogin"
}
