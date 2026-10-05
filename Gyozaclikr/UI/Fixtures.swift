import AppKit
import Foundation

/// Realistic content for previews and snapshots, so every state of the box
/// is designed against real lengths: an email paragraph, a captured
/// image with words in it, a word under the pointer, both engines'
/// diagnostics, three past requests.
enum UIFixtures {
    static let now = Date(timeIntervalSince1970: 1_791_200_000)
    static let mail = SourceApp(pid: 611, name: "Mail", bundleIdentifier: "com.apple.mail")
    static let safari = SourceApp(pid: 612, name: "Safari", bundleIdentifier: "com.apple.Safari")

    static let emailParagraph = """
        Hi Dana, just checking whether you had a chance to look at the Q4 planning doc I sent on Tuesday. \
        We'd need your numbers for the hardware line by Friday so finance can close the forecast, and if \
        anything in the assumptions looks off to you, let's grab fifteen minutes before then.
        """

    static let textSelection = Selection(
        kind: .text, text: emailParagraph,
        bounds: CGRect(x: 420, y: 512, width: 560, height: 54), sourceApp: mail, isEditable: true, tokenEstimate: 412)

    static let readOnlySelection = Selection(
        kind: .text, text: emailParagraph,
        bounds: CGRect(x: 420, y: 512, width: 560, height: 54), sourceApp: safari, isEditable: false, tokenEstimate: 412)

    static let wordSelection = Selection(kind: .word, word: "serendipity", sourceApp: safari)

    /// A 320×120 capture with a few words in it, as a region of a page would look.
    static let imageSelection = Selection(
        kind: .image, text: "Total due 1,284.00 · Invoice 2026-0417 · Net 30",
        image: ImagePayload(png: renderedImagePNG, pointSize: CGSize(width: 320, height: 120), scale: 1),
        bounds: CGRect(x: 300, y: 400, width: 320, height: 120), sourceApp: safari, isEditable: false, ocrWordCount: 83)

    static let renderedImagePNG: Data = {
        let size = NSSize(width: 320, height: 120)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 16, y: 20, width: 288, height: 1).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.35, alpha: 1)]
            let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
            ("Invoice 2026-0417" as NSString).draw(at: NSPoint(x: 16, y: 84), withAttributes: title)
            ("Net 30 · due 7 November" as NSString).draw(at: NSPoint(x: 16, y: 60), withAttributes: body)
            ("Total due   1,284.00" as NSString).draw(at: NSPoint(x: 16, y: 30), withAttributes: mono)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }()

    // MARK: Engines, permissions, history

    static let diagnostics = EngineDiagnostics(
        apple: .ready, contextSize: 4096, variant: "27.0 · 3B", imageInput: .supported,
        supportedLanguages: ["en", "fr", "de", "es", "it", "pt", "ja", "ko", "zh", "nl", "sv", "da"],
        ollama: .ready, ollamaModels: ["qwen3-vl:8b", "hermes3:8b", "gemma3:27b"], ollamaVisionModel: "qwen3-vl:8b",
        measuredAt: now)

    static let diagnosticsOffline = EngineDiagnostics(
        apple: .unavailable("Apple Intelligence is turned off. Turn it on in System Settings."),
        contextSize: nil, variant: nil, imageInput: .notInThisBuild, supportedLanguages: [],
        ollama: .unavailable("Ollama is not running."), ollamaModels: [], ollamaVisionModel: nil, measuredAt: now)

    static let permissions: [Permission: PermissionState] = [
        .accessibility: .granted, .screenRecording: .notDetermined, .reminders: .granted,
        .calendar: .denied, .automationNotes: .notDetermined, .contacts: .notDetermined,
    ]

    static let allGranted: [Permission: PermissionState] = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, .granted) })

    static let history: [HistoryEntry] = [
        HistoryEntry(date: now.addingTimeInterval(-240), requestText: "", chip: "Formal", selectionPreview: "Hi Dana, just checking…",
                     answerText: formalAnswer, engine: "Apple Intelligence"),
        HistoryEntry(date: now.addingTimeInterval(-3_900), requestText: "what is this", chip: nil, selectionPreview: "Invoice 2026-0417",
                     answerText: "An invoice dated 17 April 2026 for 1,284.00, payable within 30 days.", engine: "Ollama"),
        HistoryEntry(date: now.addingTimeInterval(-86_400 * 2), requestText: "remind me friday 9am", chip: nil, selectionPreview: "We'd need your numbers…",
                     answerText: "Reminder: Send hardware numbers to Dana · Fri 9 Oct, 09:00", engine: "Apple Intelligence"),
    ]

    // MARK: Answers

    static let formalAnswer = """
        Dear Dana,

        I am writing to ask whether you have had an opportunity to review the Q4 planning document sent on Tuesday. \
        We would need your figures for the hardware line by Friday so that Finance can close the forecast.

        Should any of the assumptions appear incorrect, I would welcome a fifteen-minute conversation before then.
        """

    static let halfAnswer = "Dear Dana,\n\nI am writing to ask whether you have had an opportunity to review the Q4 planning document sent on"

    static let listAnswer = """
        **Three things to do**

        - Review the Q4 planning doc sent on Tuesday
        - Send the hardware line numbers by **Friday**
          - Finance closes the forecast after that
        - Book fifteen minutes if any assumption looks off

        1. Reply to Dana
        2. Block the slot

        ```
        due: 2026-10-09T09:00
        ```
        """

    static let imageAnswer = "An invoice, number 2026-0417, with a total due of 1,284.00 and payment terms of"

    // MARK: Models for each snapshot

    static func model(_ state: BoxState, selection: Selection = textSelection) -> BoxModel {
        let model = BoxModel()
        model.present(selection, chips: Chip.allCases, suggested: .fix)
        switch state {
        case .hidden, .empty:
            break
        case .typing:
            model.inputChanged("make this fo")
        case .streaming:
            model.begin(status: "Rewriting…", engine: .apple, request: "Formal")
            model.setAnswer(halfAnswer)
        case .done:
            model.begin(status: "Rewriting…", engine: .apple, request: "Formal")
            model.finish(Answer(text: formalAnswer, engine: .apple))
        case .failed:
            model.begin(status: "Rewriting…", engine: .apple, request: "Formal")
            model.fail(.refused)
        case .confirming:
            model.begin(status: "Drafting…", engine: .apple, request: "send this to dana@example.com in formal style")
            model.confirm(.sendMail(to: ["dana@example.com"], subject: "Q4 planning: hardware numbers by Friday",
                                    body: formalAnswer))
        case .asking:
            model.begin(status: "Reading…", engine: .apple, request: "send this to dana")
            model.ask("Which Dana?", options: ["dana@example.com", "dana.k@work.example", "Someone else…"])
        }
        return model
    }

    /// The Ollama state: an image question, twelve seconds in.
    static func ollamaModel() -> BoxModel {
        let model = BoxModel()
        model.present(imageSelection, chips: [.summarise, .list], suggested: .summarise)
        model.begin(status: "Describing…", engine: .ollama, request: "/local what is this")
        model.engineModelName = "Qwen3-VL-8B"
        model.elapsed = 12
        model.setAnswer(imageAnswer)
        return model
    }

    static func settingsModel(diagnostics: EngineDiagnostics = diagnostics) -> SettingsModel {
        let model = SettingsModel(defaults: UserDefaults(suiteName: "ui-fixtures-\(UUID().uuidString)") ?? .standard)
        model.diagnostics = diagnostics
        model.permissions = permissions
        model.history = history
        model.readOpenAtLogin = { false }
        model.writeOpenAtLogin = { _ in }
        return model
    }

    static func menuModel() -> StatusMenuModel {
        StatusMenuModel(shortcutText: "⌃Space", diagnostics: diagnostics, permissions: permissions, hasLastAnswer: true)
    }
}
