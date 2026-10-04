import Foundation

/// The `library.json` manifest inside a `.mlibm` library file (A0 D6).
///
/// Deliberately tiny: readable without SQLite, written atomically, and tolerant of
/// unknown keys so a newer app's additions don't break an older reader. Not to be
/// confused with the sync profile's `LibraryManifest` (`mlm-library.json`).
struct LibraryPackageManifest: Codable, Equatable, Sendable {
    static let fileName = "library.json"
    static let currentVersion = 1

    var manifestVersion: Int
    var libraryId: String
    var name: String
    var createdAt: Date
    /// Last applied migration identifier. Informational only — the migrator is the
    /// authority on schema state.
    var schemaVersion: String?

    init(
        manifestVersion: Int = LibraryPackageManifest.currentVersion,
        libraryId: String,
        name: String,
        createdAt: Date,
        schemaVersion: String?
    ) {
        self.manifestVersion = manifestVersion
        self.libraryId = libraryId
        self.name = name
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case libraryId = "library_id"
        case name
        case createdAt = "created_at"
        case schemaVersion = "schema_version"
    }

    enum ReadError: Error, Equatable {
        case missing
        case malformed
        case unsupportedVersion(Int)
    }

    // MARK: - Read / write

    static func read(from url: URL) throws -> LibraryPackageManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReadError.missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.malformed
        }
        let manifest: LibraryPackageManifest
        do {
            manifest = try LibraryJSON.decoder.decode(LibraryPackageManifest.self, from: data)
        } catch {
            throw ReadError.malformed
        }
        guard manifest.manifestVersion <= currentVersion else {
            throw ReadError.unsupportedVersion(manifest.manifestVersion)
        }
        guard !manifest.libraryId.isEmpty else { throw ReadError.malformed }
        return manifest
    }

    func write(to url: URL) throws {
        try AtomicFileWriter.write(try LibraryJSON.encoder.encode(self), to: url)
    }
}

// MARK: - Shared JSON + atomic write helpers for library files

/// JSON coding shared by the manifest and the registry: ISO 8601 dates, stable key order.
enum LibraryJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Writes a file via a temp file in the same directory plus a rename, so readers see
/// either the old or the new content, never a partial file. The temp file is removed
/// when anything fails.
enum AtomicFileWriter {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            if rename(temp.path, url.path) != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                ])
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
