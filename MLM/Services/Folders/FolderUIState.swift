import Foundation

// MARK: - What Folders remembers per library (UserDefaults)

/// The outline's state between visits and launches, per library and library folder: which
/// folders are open and the last root (`Open ⌘↓`). UI state only — never in the library file.
///
/// Stored paths are relative to the library folder and checked when read: a path that would
/// leave the library folder (`..`, absolute) is discarded, and a different library folder
/// starts fresh (the old paths mean nothing there).
struct FolderUIState: Equatable, Sendable {
    var expanded: Set<String> = []
    var root: String = ""

    static let keyPrefix = "folders.state."

    /// One key per library (its id) and library folder.
    static func key(libraryID: String?, libraryRoot: String) -> String {
        keyPrefix + (libraryID ?? "default") + "|" + FolderPath.trimmedRoot(libraryRoot)
    }

    static func load(libraryID: String?, libraryRoot: String, defaults: UserDefaults) -> FolderUIState {
        let key = key(libraryID: libraryID, libraryRoot: libraryRoot)
        guard let stored = defaults.dictionary(forKey: key) else { return FolderUIState() }
        // Checked before normalising: `/abs` must not turn into the relative `abs`.
        let expanded = (stored["expanded"] as? [String] ?? [])
            .filter(FolderPath.isSafe)
            .map(FolderPath.normalize)
            .filter { !$0.isEmpty }
        let rawRoot = stored["root"] as? String ?? ""
        let root = FolderPath.isSafe(rawRoot) ? FolderPath.normalize(rawRoot) : ""
        return FolderUIState(expanded: Set(expanded), root: root)
    }

    func save(libraryID: String?, libraryRoot: String, defaults: UserDefaults) {
        let key = Self.key(libraryID: libraryID, libraryRoot: libraryRoot)
        defaults.set(["expanded": expanded.sorted(), "root": root], forKey: key)
    }

    /// Settings of library folders this library no longer uses are dropped (a changed library
    /// folder starts with a closed outline at its top).
    static func forgetOtherFolders(libraryID: String?, keeping libraryRoot: String, defaults: UserDefaults) {
        let keep = key(libraryID: libraryID, libraryRoot: libraryRoot)
        let mine = keyPrefix + (libraryID ?? "default") + "|"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(mine) && key != keep {
            defaults.removeObject(forKey: key)
        }
    }
}
