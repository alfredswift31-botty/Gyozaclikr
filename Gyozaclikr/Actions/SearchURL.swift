import Foundation

/// A web search in the default browser: DuckDuckGo with the query and nothing
/// else, no tracking parameters.
nonisolated enum SearchURL {
    static let base = "https://duckduckgo.com/?q="

    /// Unreserved ASCII only, so every other character is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func make(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: base + encoded)
    }
}
