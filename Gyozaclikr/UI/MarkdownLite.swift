import Foundation

/// The light Markdown the box renders (docs/DESIGN.md "Streaming"): bold
/// runs, inline code, bullet and numbered lists (nested by indentation),
/// fenced code. No headings (a `#` line becomes a bold paragraph), no
/// tables (they arrive as CSV and are copied, not drawn), no links. A
/// stray asterisk stays an asterisk. Pure, so it is tested without a view.
nonisolated enum MarkdownLite {
    enum Inline: Hashable, Sendable {
        case text(String)
        case bold(String)
        case code(String)
    }

    struct Item: Hashable, Sendable {
        var inlines: [Inline]
        /// Nesting depth from leading spaces (two or more per level) or tabs.
        var depth: Int
        /// The number before a numbered item, as written.
        var number: Int?
    }

    enum Block: Hashable, Sendable {
        case paragraph([Inline])
        case bullets([Item])
        case numbered([Item])
        case code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [Item] = []
        var numbered: [Item] = []
        var fence: [String]?

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlines(paragraph.joined(separator: " "))))
            paragraph = []
        }
        func closeLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if var open = fence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.append(line)
                    fence = open
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                closeParagraph(); closeLists()
                fence = []
                continue
            }
            if trimmed.isEmpty {
                closeParagraph(); closeLists()
                continue
            }
            let depth = indentation(of: line)
            if let rest = bulletBody(trimmed) {
                closeParagraph()
                if !numbered.isEmpty { closeLists() }
                bullets.append(Item(inlines: inlines(rest), depth: depth, number: nil))
                continue
            }
            if case let (number, rest)? = numberedBody(trimmed) {
                closeParagraph()
                if !bullets.isEmpty { closeLists() }
                numbered.append(Item(inlines: inlines(rest), depth: depth, number: number))
                continue
            }
            closeLists()
            if trimmed.hasPrefix("#") {
                // No headings: the text stays, bold, as its own paragraph.
                closeParagraph()
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.paragraph([.bold(title)]))
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = fence { blocks.append(.code(open.joined(separator: "\n"))) }
        closeParagraph(); closeLists()
        return blocks
    }

    /// Lines as the box lays them out: one per paragraph line, list item or
    /// code line. Decides when "Open in new window" appears.
    static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    // MARK: Lines

    private static func indentation(of line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 2 } else { break }
        }
        return spaces / 2
    }

    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedBody(_ line: String) -> (Int, String)? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber, digits.count < 4 {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits), rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Runs

    /// `**bold**` and `` `code` `` runs. An unmatched marker is kept as text.
    static func inlines(_ text: String) -> [Inline] {
        var result: [Inline] = []
        var plain = ""
        var rest = Substring(text)

        func flushPlain() {
            if !plain.isEmpty { result.append(.text(plain)); plain = "" }
        }

        while !rest.isEmpty {
            if rest.hasPrefix("**") {
                let body = rest.dropFirst(2)
                if let close = body.range(of: "**"), !body[body.startIndex..<close.lowerBound].isEmpty {
                    flushPlain()
                    result.append(.bold(String(body[body.startIndex..<close.lowerBound])))
                    rest = body[close.upperBound...]
                    continue
                }
                plain.append("**")
                rest = body
                continue
            }
            if rest.first == "`" {
                let body = rest.dropFirst()
                if let close = body.firstIndex(of: "`"), close > body.startIndex {
                    flushPlain()
                    result.append(.code(String(body[body.startIndex..<close])))
                    rest = body[body.index(after: close)...]
                    continue
                }
                plain.append("`")
                rest = body
                continue
            }
            plain.append(rest.removeFirst())
        }
        flushPlain()
        return result
    }

    /// The text with the markers removed: what Copy puts on the pasteboard
    /// for a plain-text field, and what VoiceOver reads.
    static func plainText(_ text: String) -> String {
        parse(text).map { block -> String in
            switch block {
            case .paragraph(let runs): runs.map(\.string).joined()
            case .bullets(let items): items.map { String(repeating: "  ", count: $0.depth) + "• " + $0.inlines.map(\.string).joined() }.joined(separator: "\n")
            case .numbered(let items): items.map { String(repeating: "  ", count: $0.depth) + "\($0.number ?? 0). " + $0.inlines.map(\.string).joined() }.joined(separator: "\n")
            case .code(let code): code
            }
        }.joined(separator: "\n\n")
    }
}

extension MarkdownLite.Inline {
    var string: String {
        switch self {
        case .text(let s), .bold(let s), .code(let s): s
        }
    }
}
