import Testing
import Foundation
@testable import MLM

/// Pure-logic tests for the remote-playlists window layer.
/// Covers window-title mapping per source and Equatable conformance
/// on RemotePlaylistSource (needed so AppDelegate can detect
/// "already showing this source" and focus rather than rebuild).
@Suite("RemotePlaylistsWindowTests")
struct RemotePlaylistsWindowTests {

    // MARK: - windowTitle

    @Test
    func windowTitleCoversEverySource() {
        #expect(RemotePlaylistSource.soundcloud.windowTitle == "SoundCloud Playlists")
        #expect(RemotePlaylistSource.spotify.windowTitle == "Spotify Playlists")
        #expect(RemotePlaylistSource.youtube.windowTitle == "Import YouTube Playlist")
    }

    @Test
    func windowTitlesAreDistinct() {
        let titles: [String] = [
            RemotePlaylistSource.soundcloud.windowTitle,
            RemotePlaylistSource.spotify.windowTitle,
            RemotePlaylistSource.youtube.windowTitle,
        ]
        #expect(Set(titles).count == titles.count,
                "Window titles must be pairwise distinct so a reused window never shows a stale title")
    }

    // MARK: - Equatable

    @Test
    func remotePlaylistSourceIsEquatable() {
        #expect(RemotePlaylistSource.soundcloud == RemotePlaylistSource.soundcloud)
        #expect(RemotePlaylistSource.spotify == RemotePlaylistSource.spotify)
        #expect(RemotePlaylistSource.youtube == RemotePlaylistSource.youtube)
        #expect(RemotePlaylistSource.soundcloud != RemotePlaylistSource.spotify)
        #expect(RemotePlaylistSource.soundcloud != RemotePlaylistSource.youtube)
        #expect(RemotePlaylistSource.spotify != RemotePlaylistSource.youtube)
    }
}
