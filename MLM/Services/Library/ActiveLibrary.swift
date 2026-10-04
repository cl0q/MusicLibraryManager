import Foundation

/// Where the library to open lives: inside a library file, or — until adoption — at the
/// pre-A3 loose database location.
enum LibraryLocation: Equatable, Sendable {
    case package(URL)
    case legacy(URL)

    var databaseURL: URL {
        switch self {
        case .package(let package): return LibraryPackage.databaseURL(in: package)
        case .legacy(let database): return database
        }
    }

    var packageURL: URL? {
        if case .package(let package) = self { return package }
        return nil
    }
}

/// The one library this process has open (A0 D4). Library-scoped derived data that is keyed
/// by track ID (waveforms, the default transcode cache) is namespaced by its `library_id`.
struct ActiveLibrary: Equatable, Sendable {
    let databaseURL: URL
    /// `""` for a legacy database that has no library id yet.
    let libraryId: String
    /// `nil` while the library still uses the pre-A3 layout.
    let packageURL: URL?

    var isLegacyLayout: Bool { packageURL == nil }

    /// `<base>/<library_id>`, or `base` itself for a database without a library id.
    func namespacedCacheDirectory(in base: URL) -> URL {
        libraryId.isEmpty ? base : base.appendingPathComponent(libraryId)
    }

    private static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Shared root of the per-library waveform caches.
    static var defaultWaveformCacheRoot: URL {
        cachesDirectory.appendingPathComponent("com.musiclibrary.app/waveforms")
    }

    /// Shared root of the per-library transcode caches, used when no custom path is set.
    static var defaultTranscodeCacheRoot: URL {
        cachesDirectory.appendingPathComponent("com.mlm.transcode_cache")
    }
}
