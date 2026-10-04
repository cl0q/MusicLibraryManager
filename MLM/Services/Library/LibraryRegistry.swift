import Foundation

/// Whether a registered library file can be opened right now. User-facing words:
/// `Not found` / `Not connected` (UI-GROUNDTRUTH §1.5).
enum LibraryAvailability: Equatable, Sendable {
    case available
    /// Not at its last known location, although its volume (if any) is mounted.
    case notFound
    /// On a volume under `/Volumes` that isn't mounted.
    case notConnected
}

/// The machine-local list of known libraries, `libraries.json` (A0 D5).
///
/// Lives outside every database, so it can be read before any library is opened.
/// `name` is only a display cache; the library file's manifest is authoritative.
struct LibraryRegistry: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var registryVersion: Int
    var libraries: [Entry]
    var lastActiveLibraryId: String?
    var rememberLastLibrary: Bool

    init(
        libraries: [Entry] = [],
        lastActiveLibraryId: String? = nil,
        rememberLastLibrary: Bool = true
    ) {
        self.registryVersion = Self.currentVersion
        self.libraries = libraries
        self.lastActiveLibraryId = lastActiveLibraryId
        self.rememberLastLibrary = rememberLastLibrary
    }

    enum CodingKeys: String, CodingKey {
        case registryVersion = "registry_version"
        case libraries
        case lastActiveLibraryId = "last_active_library_id"
        case rememberLastLibrary = "remember_last_library"
    }

    struct Entry: Codable, Equatable, Sendable {
        var libraryId: String
        /// Absolute path; paths inside the home folder are stored with `~`.
        var path: String
        var name: String
        var lastOpenedAt: Date?

        /// Without a trailing slash, also when the library file exists (it is a directory),
        /// so URLs from the registry compare equal to the ones the app builds.
        var url: URL {
            URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .notDirectory)
        }

        enum CodingKeys: String, CodingKey {
            case libraryId = "library_id"
            case path
            case name
            case lastOpenedAt = "last_opened_at"
        }
    }

    // MARK: - Queries

    func entry(withId libraryId: String) -> Entry? {
        libraries.first { $0.libraryId == libraryId }
    }

    func entry(at url: URL) -> Entry? {
        let target = url.standardizedFileURL.path
        return libraries.first { $0.url.standardizedFileURL.path == target }
    }

    var lastActiveEntry: Entry? {
        lastActiveLibraryId.flatMap { entry(withId: $0) }
    }

    /// Most recently opened first; never-opened entries last, in registry order.
    var recentEntries: [Entry] {
        libraries.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastOpenedAt, rhs.element.lastOpenedAt) {
            case let (l?, r?): return l != r ? l > r : lhs.offset < rhs.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Mutations

    /// Adds the library, or re-points an existing entry with the same id (moved/renamed file).
    /// One path holds one library: an entry of another id at the same path is replaced.
    mutating func upsert(libraryId: String, url: URL, name: String) {
        let path = (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
        let target = url.standardizedFileURL.path
        let replaced = libraries.filter { $0.libraryId != libraryId && $0.url.standardizedFileURL.path == target }
        libraries.removeAll { entry in replaced.contains(entry) }
        if let last = lastActiveLibraryId, replaced.contains(where: { $0.libraryId == last }) {
            lastActiveLibraryId = nil
        }
        if let index = libraries.firstIndex(where: { $0.libraryId == libraryId }) {
            libraries[index].path = path
            libraries[index].name = name
        } else {
            libraries.append(Entry(libraryId: libraryId, path: path, name: name, lastOpenedAt: nil))
        }
    }

    mutating func markOpened(libraryId: String, at date: Date) {
        guard let index = libraries.firstIndex(where: { $0.libraryId == libraryId }) else { return }
        libraries[index].lastOpenedAt = date
        lastActiveLibraryId = libraryId
    }

    // MARK: - Availability

    static func availability(
        of url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> LibraryAvailability {
        let path = url.standardizedFileURL.path
        if fileExists(path) { return .available }
        if let volume = MountObserver.extractVolumePath(from: path), !fileExists(volume) {
            return .notConnected
        }
        return .notFound
    }
}

/// Loads and saves `libraries.json`. Both locations are injected; production uses
/// `…/Application Support/com.musiclibrary.app/`.
struct LibraryRegistryStore: Sendable {
    let fileURL: URL
    let librariesDirectory: URL

    private static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.musiclibrary.app")
    }

    static var defaultFileURL: URL { appSupportDirectory.appendingPathComponent("libraries.json") }
    static var defaultLibrariesDirectory: URL { appSupportDirectory.appendingPathComponent("libraries") }

    init(fileURL: URL = defaultFileURL, librariesDirectory: URL = defaultLibrariesDirectory) {
        self.fileURL = fileURL
        self.librariesDirectory = librariesDirectory
    }

    enum LoadOutcome: Equatable, Sendable {
        case loaded
        /// No registry file; rebuilt by scanning `librariesDirectory`.
        case rebuiltMissing
        /// Unreadable registry file, kept at `preservedAt`; rebuilt by scanning.
        case rebuiltCorrupt(preservedAt: URL)
    }

    enum LoadError: Error, Equatable {
        /// Written by a newer MLM. Left untouched.
        case unsupportedVersion(Int)
    }

    /// Reads the registry. A missing or unreadable file is rebuilt from the library files
    /// in `librariesDirectory`; an unreadable file is first renamed to
    /// `libraries.json.corrupt-<timestamp>`, never overwritten.
    func load(now: Date = Date()) throws -> (registry: LibraryRegistry, outcome: LoadOutcome) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let rebuilt = rebuildByScan()
            if !rebuilt.libraries.isEmpty { try save(rebuilt) }
            return (rebuilt, .rebuiltMissing)
        }

        if let data = try? Data(contentsOf: fileURL),
           let registry = try? LibraryJSON.decoder.decode(LibraryRegistry.self, from: data) {
            guard registry.registryVersion <= LibraryRegistry.currentVersion else {
                throw LoadError.unsupportedVersion(registry.registryVersion)
            }
            return (registry, .loaded)
        }
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object[LibraryRegistry.CodingKeys.registryVersion.rawValue] as? Int,
           version > LibraryRegistry.currentVersion {
            throw LoadError.unsupportedVersion(version)
        }

        let preserved = corruptCopyURL(now: now)
        try fileManager.moveItem(at: fileURL, to: preserved)
        let rebuilt = rebuildByScan()
        try save(rebuilt)
        return (rebuilt, .rebuiltCorrupt(preservedAt: preserved))
    }

    func save(_ registry: LibraryRegistry) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFileWriter.write(try LibraryJSON.encoder.encode(registry), to: fileURL)
    }

    /// Registry built from every readable `*.mlibm` manifest in `librariesDirectory`,
    /// sorted by file name. A library id seen twice (a Finder copy) keeps the first file.
    /// With exactly one library, it becomes the active one.
    func rebuildByScan() -> LibraryRegistry {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: librariesDirectory.path)) ?? []
        var registry = LibraryRegistry()
        for name in names.sorted() where (name as NSString).pathExtension == LibraryPackage.fileExtension {
            let package = librariesDirectory.appendingPathComponent(name)
            guard let manifest = try? LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package)),
                  registry.entry(withId: manifest.libraryId) == nil else { continue }
            registry.upsert(libraryId: manifest.libraryId, url: package, name: manifest.name)
        }
        if registry.libraries.count == 1 {
            registry.lastActiveLibraryId = registry.libraries[0].libraryId
        }
        return registry
    }

    private func corruptCopyURL(now: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: now)
        let directory = fileURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        return candidate
    }
}
