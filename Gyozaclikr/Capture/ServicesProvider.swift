import AppKit

// The Services-menu entry "Ask Gyozaclikr" (NSServices in Config/Info.plist).
// It needs no permission: macOS hands the selection over on a private
// pasteboard, in every app with a Services menu, including the ones where
// Accessibility reads nothing (docs/research/system-integration.md §2).

final class ServicesProvider: NSObject {
    /// Called with the selection the service received; set by the coordinator.
    var onSelection: ((Selection) -> Void)?

    private let recognizer: TextRecognizer

    init(recognizer: TextRecognizer = TextRecognizer()) {
        self.recognizer = recognizer
    }

    /// Make this object the app's services provider and refresh the menu.
    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// The NSMessage handler: `askGyozaclikr:userData:error:`.
    @objc func askGyozaclikr(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let selection = Self.selection(from: pasteboard) else {
            error.pointee = "Gyozaclikr needs text or an image."
            return
        }
        if selection.kind == .image {
            Task { [recognizer] in
                self.onSelection?(await Self.withOCR(selection, recognizer: recognizer))
            }
        } else {
            onSelection?(selection)
        }
    }

    /// The pasteboard as a selection, with the OCR text for an image.
    func handle(pasteboard: NSPasteboard) async -> Selection? {
        guard let selection = Self.selection(from: pasteboard) else { return nil }
        guard selection.kind == .image else { return selection }
        return await Self.withOCR(selection, recognizer: recognizer)
    }

    /// Text wins over an image; both come from the sender's own types.
    static func selection(from pasteboard: NSPasteboard) -> Selection? {
        let sourceApp = SelectionReader.frontmostApp()
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Selection(kind: .text, text: text, sourceApp: sourceApp, isEditable: false,
                             tokenEstimate: TokenEstimate.estimate(text))
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), let rep = NSBitmapImageRep(data: data),
                  let cgImage = rep.cgImage, let image = ImagePayload(cgImage: cgImage) else { continue }
            return Selection(kind: .image, image: image, sourceApp: sourceApp, isEditable: false)
        }
        return nil
    }

    private static func withOCR(_ selection: Selection, recognizer: TextRecognizer) async -> Selection {
        var selection = selection
        guard let cgImage = selection.image?.cgImage, let ocr = try? await recognizer.recognize(cgImage) else {
            selection.ocrWordCount = 0
            return selection
        }
        selection.text = ocr.text.isEmpty ? nil : ocr.text
        selection.tokenEstimate = ocr.text.isEmpty ? nil : TokenEstimate.estimate(ocr.text)
        selection.ocrWordCount = ocr.wordCount
        return selection
    }
}
