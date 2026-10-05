import Foundation

/// How much of the context window a selection may take. The window holds
/// instructions, the prompt, the selection and the answer together, so the
/// selection gets what is left after the fixed parts and a reserve for the
/// answer, never more than the ceiling the design promises.
nonisolated enum SelectionBudget {
    /// Tokens kept free for the model's answer.
    static let outputReserve = 600
    /// The most selection tokens one request takes (docs/research/product-and-ux.md §B).
    static let ceiling = 2_600
    /// Apple's documented window when the SDK cannot report it.
    static let defaultContextSize = 4_096
    /// Latin text runs 3–4 characters per token; the estimate errs on the high side.
    static let charactersPerToken = 3.5

    static func limit(contextSize: Int, instructionTokens: Int, promptTokens: Int) -> Int {
        max(0, min(ceiling, contextSize - instructionTokens - promptTokens - outputReserve))
    }

    /// A token count without the model (before macOS 26.4, or when the model is off).
    static func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, Int((Double(text.count) / charactersPerToken).rounded(.up)))
    }

    /// Prompts whose answer survives map-reduce: a summary of summaries is
    /// still a summary. A rewrite of a long text is not chunked; it is refused
    /// with the two numbers so the user can select less.
    static func isSummaryLike(_ prompt: String) -> Bool {
        // Whole words: "register" contains "gist".
        prompt.range(of: #"\b(summar\w*|tl;?dr|gist|key points|main points|overview|in brief|recap)\b"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Splits a long selection into pieces that fit the budget, by paragraph
/// first, then by line, then by length, so each piece reads as prose.
nonisolated enum Chunker {
    /// Paragraphs: runs of text separated by one or more blank lines.
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .reduce(into: [[String]]()) { groups, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !(groups.last?.isEmpty ?? true) { groups.append([]) }
                } else if groups.isEmpty {
                    groups.append([line])
                } else {
                    groups[groups.count - 1].append(line)
                }
            }
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Pieces of `text` each at most `budget` tokens by `tokens`. Consecutive
    /// paragraphs are packed together while they fit; a paragraph that alone
    /// exceeds the budget is split by line, then by characters.
    static func chunks(of text: String, budget: Int, tokens: (String) async throws -> Int) async rethrows -> [String] {
        let budget = max(budget, 1)
        var pieces: [(text: String, tokens: Int)] = []
        for paragraph in paragraphs(of: text) {
            let count = try await tokens(paragraph)
            if count <= budget {
                pieces.append((paragraph, count))
            } else {
                pieces += try await split(paragraph, budget: budget, tokens: tokens)
            }
        }

        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0
        for piece in pieces {
            // One token per join is a safe over-estimate of the separator.
            let joined = currentTokens + piece.tokens + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, joined > budget {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                currentTokens = 0
            }
            current.append(piece.text)
            currentTokens += piece.tokens + (current.count > 1 ? 1 : 0)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    private static func split(_ paragraph: String, budget: Int, tokens: (String) async throws -> Int) async rethrows -> [(text: String, tokens: Int)] {
        var result: [(text: String, tokens: Int)] = []
        let lines = paragraph.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for line in lines {
            let count = try await tokens(line)
            if count <= budget {
                result.append((line, count))
                continue
            }
            // A single line longer than the budget: cut it by characters in
            // proportion to the budget, with a margin, at a word boundary
            // where there is one.
            let length = max(1, Int(Double(line.count) * Double(budget) / Double(count) * 0.8))
            var rest = Substring(line)
            while !rest.isEmpty {
                var piece = rest.prefix(length)
                if piece.count == length, let space = piece.lastIndex(of: " "), space > piece.startIndex {
                    piece = rest[rest.startIndex...space]
                }
                let text = String(piece).trimmingCharacters(in: .whitespaces)
                rest = rest[piece.endIndex...]
                if !text.isEmpty {
                    result.append((text, try await tokens(text)))
                }
            }
        }
        return result
    }
}
