import CoreGraphics
import Foundation
import Vision

// Live Text for a captured region: Vision's RecognizeTextRequest, the Swift
// API from macOS 15. Vision returns boxes in no promised order; OCRLayout
// puts them back into lines, top to bottom, so the text reads as it was laid out.

/// Orders recognised boxes into lines. Pure, so it is tested with fixtures.
nonisolated enum OCRLayout {
    /// One recognised string and its box in Vision's normalised image
    /// coordinates: origin bottom-left, 0…1 on both axes.
    struct Box: Hashable, Sendable {
        let text: String
        let frame: CGRect
    }

    /// Boxes whose vertical centres differ by less than this fraction of
    /// their height sit on one line.
    static let lineTolerance: CGFloat = 0.5

    static func lines(_ boxes: [Box]) -> [[Box]] {
        let sorted = boxes.filter { !$0.text.isEmpty }.sorted { $0.frame.midY > $1.frame.midY }
        var lines: [[Box]] = []
        for box in sorted {
            if var line = lines.last, let anchor = line.first,
               abs(anchor.frame.midY - box.frame.midY) < min(anchor.frame.height, box.frame.height) * lineTolerance {
                line.append(box)
                lines[lines.count - 1] = line
            } else {
                lines.append([box])
            }
        }
        return lines.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// The text, one line per visual line, words separated by one space.
    static func join(_ boxes: [Box]) -> String {
        lines(boxes).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// The OCR text of an image with the count the box shows ("OCR · 83 words").
nonisolated struct OCRResult: Hashable, Sendable {
    let text: String
    let wordCount: Int
    let lines: [String]

    static let empty = OCRResult(text: "", wordCount: 0, lines: [])
}

/// Runs Vision's accurate recogniser with language detection on a CGImage.
nonisolated struct TextRecognizer: Sendable {
    /// Words the recogniser should keep as they are (a product name in a test image).
    var customWords: [String] = []

    init(customWords: [String] = []) {
        self.customWords = customWords
    }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.customWords = customWords
        let observations = try await request.perform(on: image, orientation: nil)
        let boxes = observations.map { OCRLayout.Box(text: $0.transcript, frame: $0.boundingBox.cgRect) }
        let text = OCRLayout.join(boxes)
        return OCRResult(text: text, wordCount: OCRLayout.wordCount(text),
                         lines: OCRLayout.lines(boxes).map { $0.map(\.text).joined(separator: " ") })
    }
}
