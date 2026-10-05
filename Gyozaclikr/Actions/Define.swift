import CoreServices
import Foundation

/// The system dictionary through Dictionary Services: no model, no permission.
nonisolated enum Define {
    static func lookup(_ word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (trimmed as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() else { return nil }
        let text = (definition as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
