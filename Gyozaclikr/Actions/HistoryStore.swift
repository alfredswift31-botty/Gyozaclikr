import Foundation

/// The last requests, newest first, as JSON in Application Support. Local
/// only; capped by `SettingsKey.historyLimit` (50 unless set).
final class HistoryStore {
    static let fileName = "history.json"
    static let defaultLimit = 50

    private(set) var entries: [HistoryEntry] = []
    let fileURL: URL
    private let defaults: UserDefaults

    /// `directory` defaults to ~/Library/Application Support/Gyozaclikr.
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let folder = directory ?? Self.defaultDirectory()
        fileURL = folder.appendingPathComponent(Self.fileName)
        self.defaults = defaults
        entries = Self.load(from: fileURL)
    }

    var limit: Int {
        let value = defaults.integer(forKey: SettingsKey.historyLimit)
        return value > 0 ? value : Self.defaultLimit
    }

    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience; losing a write is not worth an alert.
        }
    }

    static func load(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Gyozaclikr", isDirectory: true)
    }
}
