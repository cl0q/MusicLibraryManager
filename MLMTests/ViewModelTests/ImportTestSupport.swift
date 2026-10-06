import Foundation
import GRDB
import Testing
@testable import MLM

// MARK: - Fakes shared by the W3-ADD tests (no network, temporary databases)

/// Source accounts as the tests set them.
@MainActor
final class ImportTestAccounts: SourceAccountStateReading {
    var states: [TokenStorage.Service: SourceAccountState] = [:]
    private(set) var expired: [TokenStorage.Service] = []
    private(set) var signIns = 0
    /// What a sign-in does (default: succeeds at once).
    var onSignIn: (@MainActor () async throws -> Void)?

    func state(of service: TokenStorage.Service) -> SourceAccountState {
        states[service] ?? (service == .appleMusic ? .notAvailable : .connected(account: nil))
    }

    func reload() async {}

    func markSignInExpired(_ service: TokenStorage.Service) {
        expired.append(service)
        states[service] = .signInExpired
    }

    func signIn(_ service: TokenStorage.Service) async throws {
        signIns += 1
        try await onSignIn?()
        states[service] = .connected(account: nil)
    }

    func allowKeychainAccess(_ service: TokenStorage.Service) async -> Bool { false }
}

/// Records what an import hands to the download lane.
@MainActor
final class RecordingPlaylistDownloads: PlaylistDownloadStarting {
    private(set) var started: [(tracks: [Track], playlistID: Int64, name: String)] = []

    func startDownloads(_ tracks: [Track], preferredSource: DownloadOrchestrator.PreferredSource,
                        playlistID: Int64, playlistName: String) {
        started.append((tracks, playlistID, playlistName))
    }
}

/// A suspension point the test opens.
@MainActor
final class ImportTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var isWaiting = false

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
        isWaiting = false
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// A playlist source without network: a fixed preview, a sources row in the test database.
@MainActor
final class FakePlaylistProvider: RemotePlaylistProvider {
    let displayName: String
    let preferredSource: DownloadOrchestrator.PreferredSource = .auto
    let browseMode: RemotePlaylistBrowseMode
    var preview: RemotePlaylistPreview
    var summaries: [RemotePlaylistSummary] = []
    /// Thrown by the next preview fetch (then cleared).
    var nextError: Error?
    /// Holds `sourceRowForLinking` (the commit's first step) until opened.
    var sourceGate: ImportTestGate?
    private let sources: SourceRepository
    private let sourceName: String

    init(_ source: LinkSource, preview: RemotePlaylistPreview, database: any DatabaseWriter) {
        displayName = source.rawValue
        sourceName = source.storedName
        browseMode = source == .youtube ? .urlOnly : .accountPlaylistsAndURL
        self.preview = preview
        sources = SourceRepository(database: database)
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] { summaries }

    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
        try takeError()
        return preview
    }

    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        try takeError()
        return preview
    }

    private func takeError() throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    func sourceRowForLinking() async throws -> Source {
        await sourceGate?.wait()
        return try await sources.upsert(name: sourceName, userId: "me")
    }
}

enum ImportFixtures {
    /// `count` tracks `v1…vn` of `source`, albums set to the source name as the old previews did.
    static func preview(_ source: LinkSource = .youtube, id: String = "pl-1", title: String = "Late night rollers",
                        count: Int = 3) -> RemotePlaylistPreview {
        RemotePlaylistPreview(
            sourceName: source.rawValue, externalID: id, title: title,
            tracks: (1...count).map { index in
                RemotePlaylistTrack(externalID: "v\(index)", title: "Track \(index)", artist: "Artist \(index)",
                                    album: source.rawValue, durationSeconds: 180 + index, format: source.storedName,
                                    originalPath: "https://example.test/\(source.storedName)/v\(index)")
            })
    }

    static func url(_ source: LinkSource) -> String {
        switch source {
        case .youtube: "https://www.youtube.com/playlist?list=PL1"
        case .soundcloud: "https://soundcloud.com/someone/sets/late-night"
        case .spotify: "https://open.spotify.com/playlist/abc"
        }
    }
}
