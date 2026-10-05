import Foundation

/// How typing narrows the chip row (docs/DESIGN.md "Typing"): the last word
/// of the input is a prefix of a chip's title ("make this fo" leaves
/// Formal). When nothing matches the row stays whole: the user is writing
/// a request, not hunting a chip.
nonisolated enum ChipFilter {
    /// The word being typed: everything after the last space.
    static func prefix(of input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .newlines)
        guard let last = trimmed.split(separator: " ", omittingEmptySubsequences: false).last else { return "" }
        return String(last).lowercased()
    }

    static func matches(_ chips: [Chip], input: String) -> [Chip] {
        let word = prefix(of: input)
        guard !word.isEmpty else { return [] }
        return chips.filter { $0.title.lowercased().hasPrefix(word) }
    }

    /// The chips to show: the matches when there are any, else all of them.
    static func visible(_ chips: [Chip], input: String) -> [Chip] {
        let found = matches(chips, input: input)
        return found.isEmpty ? chips : found
    }

    /// The chip Tab accepts: the first match while typing, else the
    /// coordinator's suggestion when the input is empty.
    static func suggestion(_ chips: [Chip], input: String, preferred: Chip?) -> Chip? {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return preferred }
        return matches(chips, input: input).first
    }
}
