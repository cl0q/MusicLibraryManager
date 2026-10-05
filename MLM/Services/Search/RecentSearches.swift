import Foundation

// MARK: - Recent searches (V-SEARCH.N17, UC-SEARCH-04)

/// One remembered search: its text and tokens.
struct RecentSearch: Codable, Equatable, Identifiable, Sendable {
    var text: String
    var tokens: [SearchToken]

    init(_ filter: SearchFilter) {
        text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = filter.tokens
    }

    var filter: SearchFilter { SearchFilter(text: text, tokens: tokens) }

    /// Case-folded identity: the same search typed twice is one entry.
    var id: String {
        ([text.lowercased()] + tokens.map(\.id)).joined(separator: "\u{1F}")
    }
}

/// The last five searches of the open library, tokens included (`search.html`: “The last five,
/// tokens included. Kept per library.”). Stored in `UserDefaults` under
/// `search.recent.‹library id›` (`default` while the library has no id), newest first. Links are
/// never remembered; nor is an empty search.
final class RecentSearchStore {
    static let limit = 5

    private let defaults: UserDefaults
    private let libraryID: () -> String?

    init(defaults: UserDefaults = .standard, libraryID: @escaping () -> String?) {
        self.defaults = defaults
        self.libraryID = libraryID
    }

    static func key(libraryID: String?) -> String {
        let id = (libraryID?.isEmpty == false ? libraryID : nil) ?? "default"
        return "search.recent.\(id)"
    }

    private var key: String { Self.key(libraryID: libraryID()) }

    func load() -> [RecentSearch] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([RecentSearch].self, from: data) else { return [] }
        return Array(entries.prefix(Self.limit))
    }

    /// Puts `filter` first (moving an equal entry up), keeps five.
    @discardableResult
    func record(_ filter: SearchFilter) -> [RecentSearch] {
        guard filter.hasInput, !filter.isLink else { return load() }
        let entry = RecentSearch(filter)
        var entries = load().filter { $0.id != entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.limit))
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
        return entries
    }
}
