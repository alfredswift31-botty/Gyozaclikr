import Foundation

/// One extracted item and the words in the selection it came from. The
/// model fills both; `Verification` keeps only items whose quote is really
/// in the selection, because the 3B model invents items (docs/BRIEF.md).
nonisolated struct ExtractedQuote: Hashable, Sendable {
    var text: String
    var quote: String
}

/// One extracted table row with its quote.
nonisolated struct ExtractedTableRow: Hashable, Sendable {
    var cells: [String]
    var quote: String
}

/// Drops extracted items whose quote is not in the selection.
nonisolated enum Verification {
    /// Whitespace runs become one space, case is folded and curly quotes
    /// straightened, so a model that reflows a line still passes; a model
    /// that invents words does not.
    static func normalised(_ text: String) -> String {
        let straightened = text
            .replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’‚]", with: "'", options: .regularExpression)
        return straightened
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Whether `quote` appears in `selection` after normalisation. An empty
    /// quote never does: an item without a source is an invention.
    static func contains(_ quote: String, in selection: String) -> Bool {
        let needle = normalised(quote)
        guard !needle.isEmpty else { return false }
        return normalised(selection).contains(needle)
    }

    /// The items whose quote is in the selection, in order, plus how many were dropped.
    static func keep<Item>(_ items: [Item], quote: (Item) -> String, in selection: String) -> (kept: [Item], dropped: Int) {
        let haystack = normalised(selection)
        var kept: [Item] = []
        var dropped = 0
        for item in items {
            let needle = normalised(quote(item))
            if !needle.isEmpty, haystack.contains(needle) {
                kept.append(item)
            } else {
                dropped += 1
            }
        }
        return (kept, dropped)
    }

    static func keep(_ items: [ExtractedQuote], in selection: String) -> (kept: [ExtractedQuote], dropped: Int) {
        keep(items, quote: \.quote, in: selection)
    }

    static func keep(_ rows: [ExtractedTableRow], in selection: String) -> (kept: [ExtractedTableRow], dropped: Int) {
        keep(rows, quote: \.quote, in: selection)
    }

    /// The bulleted list the box shows for verified items.
    static func bullets(_ items: [ExtractedQuote]) -> String {
        items.map { "- " + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
    }
}

/// CSV with RFC 4180 quoting: a field with a comma, a quote or a line break
/// is wrapped in quotes and its quotes are doubled. Lines end in "\n", which
/// Numbers, Excel and the pasteboard all take.
nonisolated enum CSV {
    static func render(rows: [[String]]) -> String {
        rows.map { row in row.map(field).joined(separator: ",") }.joined(separator: "\n")
    }

    static func field(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
