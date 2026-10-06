import Foundation
import GRDB
import Testing
@testable import MLM

/// §15.5 status words, the sidebar tree, the All Playlists grid rules, the facts line, the
/// new drop-matrix cells (W3-PL) and the add-only refresh.
@Suite("Playlist presentation and refresh")
@MainActor
struct PlaylistPresentationTests {
    private func summary(total: Int, local: Int = 0, downloading: Int = 0, failed: Int = 0, notDownloaded: Int = 0) -> PlaylistSummary {
        PlaylistSummary(playlistID: 1, totalTracks: total, localTracks: local, downloadingTracks: downloading,
                        failedTracks: failed, notDownloadedTracks: notDownloaded)
    }

    // MARK: Status words (UC-STATE §15.5, exact)

    @Test func statusWordsAreVerbatimAndFollowThePrecedence() {
        #expect(PlaylistStatus.make(summary: summary(total: 44, local: 44), echo: nil, expiredSignIn: nil) == .healthy)
        #expect(PlaylistStatus.healthy.text == nil)
        let expired = PlaylistStatus.make(summary: summary(total: 44, failed: 9), echo: nil, expiredSignIn: "SoundCloud")
        #expect(expired.text == "SoundCloud sign-in expired")
        let importing = PlaylistStatus.make(summary: summary(total: 44, local: 12, downloading: 2, failed: 3), echo: nil, expiredSignIn: nil)
        #expect(importing.text == "Importing · 12 of 44")
        let incomplete = PlaylistStatus.make(summary: summary(total: 44, local: 35, failed: 9), echo: nil, expiredSignIn: nil)
        #expect(incomplete.text == "Incomplete · 9 failed")
        let notDownloaded = PlaylistStatus.make(summary: summary(total: 61, notDownloaded: 61), echo: nil, expiredSignIn: nil)
        #expect(notDownloaded.text == "Not downloaded · 61 tracks")
        #expect(PlaylistStatus.notDownloaded(count: 1).text == "Not downloaded · 1 track")
    }

    @Test func aRunningDownloadForThePlaylistUsesActivitysNumbers() {
        let echo = ActivityEcho(operationID: UUID(), kind: .download, state: .running, verb: "Importing",
                                progressText: "12 of 44", fraction: 12.0 / 44, waitText: nil, failedCount: 0, resultText: nil)
        let status = PlaylistStatus.make(summary: summary(total: 44, notDownloaded: 44), echo: echo, expiredSignIn: nil)
        #expect(status.text == "Importing · 12 of 44")
        #expect(!status.needsAttention, "a running import is not attention (UC-SCOPE-04)")
    }

    @Test func needsAttentionCoversWhatTheUserCanFix() {
        #expect(PlaylistStatus.incomplete(failed: 1).needsAttention)
        #expect(PlaylistStatus.notDownloaded(count: 2).needsAttention)
        #expect(PlaylistStatus.signInExpired(source: "Spotify").needsAttention)
        #expect(!PlaylistStatus.healthy.needsAttention)
    }

    // MARK: Tree and grid

    private func playlist(_ id: Int64, _ name: String, folder: Int64? = nil, position: String?, sourceId: Int64? = nil) -> Playlist {
        var p = Playlist.createNative(name: name)
        p.id = id
        p.folderId = folder
        p.position = position
        p.sourceId = sourceId
        return p
    }

    @Test func treeAndGridGroupsFollowTheManualOrder() {
        let folders = [PlaylistFolder(id: 10, name: "Sets", position: "b")]
        let playlists = [
            playlist(1, "Warm-up", folder: 10, position: "a"),
            playlist(2, "Road trip", position: "a"),
            playlist(3, "Closing", folder: 10, position: "c"),
            playlist(4, "Sunday", position: "c"),
            playlist(5, "Orphan", folder: 99, position: "d"),
        ]
        let tree = PlaylistSidebarTree.build(folders: folders, playlists: playlists)
        #expect(tree.playlists.map(\.name) == ["Road trip", "Warm-up", "Closing", "Sunday", "Orphan"])
        #expect(tree.itemAfter(.playlist(1)) == .playlist(3))
        #expect(tree.itemAfter(.folder(10)) == .playlist(4))

        var items: [Int64: PlaylistGridItem] = [:]
        for p in playlists {
            let status: PlaylistStatus = p.id == 4 ? .incomplete(failed: 2) : .healthy
            items[p.id!] = PlaylistGridItem(playlist: p, summary: nil, status: status, source: p.id == 3 ? .soundcloud : nil)
        }
        let manual = PlaylistGridRules.layout(tree: tree, items: items, sort: .manual, scope: .all, filter: SearchFilter())
        guard case .grouped(let groups) = manual else { Issue.record("Manual without filter groups by folder"); return }
        #expect(groups.map { $0.folder?.name ?? "-" } == ["-", "Sets", "-"])
        #expect(groups.map { $0.items.map(\.playlist.name) } == [["Road trip"], ["Warm-up", "Closing"], ["Sunday", "Orphan"]])

        let byName = PlaylistGridRules.layout(tree: tree, items: items, sort: .name, scope: .all, filter: SearchFilter())
        #expect(byName.items.map(\.playlist.name) == ["Closing", "Orphan", "Road trip", "Sunday", "Warm-up"])
        let recent = PlaylistGridRules.layout(tree: tree, items: items, sort: .recentlyAdded, scope: .all, filter: SearchFilter())
        #expect(recent.items.map(\.id) == [5, 4, 3, 2, 1])
        let attention = PlaylistGridRules.layout(tree: tree, items: items, sort: .manual, scope: .needsAttention, filter: SearchFilter())
        #expect(attention == .flat([items[4]!]))
        let filtered = PlaylistGridRules.layout(tree: tree, items: items, sort: .manual, scope: .all, filter: SearchFilter(text: "sun"))
        #expect(filtered.items.map(\.playlist.name) == ["Sunday"])

        let all = Array(items.values)
        #expect(PlaylistGridRules.scopes(all) == [.all, .local, .source(.soundcloud), .needsAttention])
        #expect(PlaylistGridRules.count(all, in: .local) == 4)
        #expect(PlaylistGridRules.statusText(shown: 28, total: 28) == "28 playlists")
        #expect(PlaylistGridRules.statusText(shown: 6, total: 28) == "6 of 28 playlists")
        #expect(PlaylistGridRules.filteredEmptyText(query: "vaporwave", scope: .source(.soundcloud)) == "Nothing is named “vaporwave” in SoundCloud.")
        #expect(PlaylistGridRules.filteredEmptyText(query: "", scope: .needsAttention) == "No playlist in Needs attention.")
        #expect(PlaylistGridSort.allCases.map(\.title) == ["Manual", "Name", "Recently Added"])
    }

    @Test func factsLineAndCardFacts() {
        #expect(PlaylistFacts.line(trackCount: 44, totalSeconds: 10260, sourceName: "SoundCloud") == "44 tracks · 2 h 51 min · Linked to SoundCloud")
        #expect(PlaylistFacts.line(trackCount: 0, totalSeconds: 0, sourceName: nil) == "0 tracks")
        var liked = Playlist.createNative(name: "Liked")
        liked.isLiked = 1
        let item = PlaylistGridItem(playlist: liked, summary: PlaylistSummary(playlistID: 1, totalTracks: 412), status: .healthy, source: .spotify)
        #expect(item.factsText == "Spotify · 412 tracks · Liked")
        #expect(PlaylistFacts.kindLabel(liked) == "Liked playlist")
    }

    // MARK: Drop matrix cells (W3-PL)

    private let context = DropContext(libraryID: "L", isLibraryOpen: true, offlineVolumeName: nil)

    @Test func playlistsMoveIntoFoldersReorderAndGoBackToTheTopLevel() {
        let playlists = DropContent.playlists([PlaylistDragItem(playlistId: 3, libraryId: "L")])
        let folderDrag = DropContent.playlists([.folder(9, libraryId: "L")])
        #expect(DropRules.accepts(.playlists, on: .playlistFolder(id: 9, name: "Sets"), context: context))
        #expect(DropRules.decide(playlists, onto: .playlistFolder(id: 9, name: "Sets"), context: context)
                == .movePlaylistItems([.playlist(3)], folderID: 9, before: nil))
        #expect(DropRules.decide(folderDrag, onto: .playlistFolder(id: 7, name: "Radio"), context: context) == .refuse(nil),
                "one level: a folder never goes into a folder")
        #expect(DropRules.decide(playlists, onto: .playlistsSection, context: context)
                == .movePlaylistItems([.playlist(3)], folderID: nil, before: nil))
        #expect(DropRules.decide(folderDrag, onto: .playlistOrder(folderID: nil, before: .playlist(4)), context: context)
                == .movePlaylistItems([.folder(9)], folderID: nil, before: .playlist(4)))
        #expect(DropRules.decide(playlists, onto: .playlistOrder(folderID: nil, before: .playlist(3)), context: context) == .refuse(nil))
        #expect(DropRules.decide(playlists, onto: .playlistCardInManualOrder(id: 5, name: "X", folderID: nil), context: context)
                == .movePlaylistItems([.playlist(3)], folderID: nil, before: .playlist(5)))
        #expect(DropRules.decide(folderDrag, onto: .sidebarPlaylist(id: 5, name: "X"), context: context) == .refuse(nil),
                "a folder row only reorders")
    }

    @Test func tracksFilesAndM3UOnAFolderMakeANewPlaylistInside() {
        let tracks = DropContent.tracks(TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "L")]))
        #expect(DropRules.decide(tracks, onto: .playlistFolder(id: 9, name: "Sets"), context: context) == .newPlaylistInFolder([1], folderID: 9))
        let m3u = DropContent.files([DroppedFile(url: URL(fileURLWithPath: "/x/a.m3u"), kind: .m3u)])
        #expect(DropRules.decide(m3u, onto: .playlistFolder(id: 9, name: "Sets"), context: context)
                == .importM3UInFolder(URL(fileURLWithPath: "/x/a.m3u"), folderID: 9))
        let audio = DropContent.files([DroppedFile(url: URL(fileURLWithPath: "/x/a.mp3"), kind: .audio)])
        #expect(DropRules.decide(audio, onto: .playlistFolder(id: 9, name: "Sets"), context: context)
                == .importFilesAsNewPlaylistInFolder([URL(fileURLWithPath: "/x/a.mp3")], folderID: 9))
    }

    // MARK: Refresh from ‹Source› (add-only, B3-PLAN §5 question 5)

    private func refreshEnv() throws -> (DatabaseQueue, PlaylistRepository, TrackRepository, SourceRepository) {
        let db = try DatabaseManager.inMemory()
        try db.write { db in
            for id in 1...4 {
                try db.execute(sql: "INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path) VALUES (?, 'A', 'A', '', ?, 'mp3', ?)",
                               arguments: [id, "T\(id)", "/t/\(id).mp3"])
            }
        }
        return (db, PlaylistRepository(database: db), TrackRepository(database: db), SourceRepository(database: db))
    }

    @Test func aLikedRefreshNeverRemovesATrack() async throws {
        let (_, playlists, tracks, sources) = try refreshEnv()
        let source = try await sources.upsert(name: "soundcloud", userId: "u")
        let liked = try await playlists.findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: source.id!, externalId: "u")
        try await playlists.replaceTrackList(playlistId: liked.id!, trackIds: [1, 2, 3])
        let service = PlaylistRefreshService(playlists: playlists, tracks: tracks, sources: sources, remote: .init(
            syncLiked: { _ in try await playlists.replaceTrackList(playlistId: liked.id!, trackIds: [4, 2]) },
            listTracks: { _, _ in [] }
        ))
        let added = try await service.refresh(playlistID: liked.id!)
        #expect(added == 1)
        let now = Set(try await playlists.fetchTracks(playlistId: liked.id!).compactMap(\.id))
        #expect(now == [1, 2, 3, 4], "1 and 3 dropped by the source sync come back")
        #expect(PlaylistRefreshService.resultText(newTracks: added) == "1 new track")
        #expect(PlaylistRefreshService.resultText(newTracks: 0) == "No new tracks")
    }

    @Test func aLinkedRefreshAppendsOnlyWhatIsNew() async throws {
        let (_, playlists, tracks, sources) = try refreshEnv()
        let source = try await sources.upsert(name: "youtube", userId: "local")
        let playlist = try await playlists.createNumbered(baseName: "Mixes", trackIds: [1])
        try await playlists.updateSourceLink(id: playlist.id!, sourceId: source.id, externalId: "https://youtube.com/playlist?list=x")
        try await sources.linkTrackToSource(trackId: 1, sourceId: source.id!, externalId: "vid-1")
        let remote = [
            RemotePlaylistTrack(externalID: "vid-new", title: "New", artist: "B", album: "", durationSeconds: 60, format: "youtube", originalPath: "https://y/new"),
            RemotePlaylistTrack(externalID: "vid-1", title: "Old", artist: "A", album: "", durationSeconds: 60, format: "youtube", originalPath: "https://y/1"),
        ]
        let service = PlaylistRefreshService(playlists: playlists, tracks: tracks, sources: sources, remote: .init(
            syncLiked: { _ in }, listTracks: { _, _ in remote }
        ))
        #expect(PlaylistRefreshService.canRefresh(try await playlists.fetch(id: playlist.id!)!))
        #expect(try await service.refresh(playlistID: playlist.id!) == 1)
        let rows = try await playlists.fetchTracks(playlistId: playlist.id!)
        #expect(rows.count == 2)
        #expect(rows.first?.id == 1, "nothing reordered")
        #expect(rows.last?.album == "", "no source name as album (DEC-013)")
        #expect(try await service.refresh(playlistID: playlist.id!) == 0, "nothing new the second time")
    }

    @Test func aLocalPlaylistCantBeRefreshed() async throws {
        let (_, playlists, tracks, sources) = try refreshEnv()
        let playlist = try await playlists.createNumbered(baseName: "Mine")
        #expect(!PlaylistRefreshService.canRefresh(playlist))
        let service = PlaylistRefreshService(playlists: playlists, tracks: tracks, sources: sources,
                                             remote: .init(syncLiked: { _ in }, listTracks: { _, _ in [] }))
        await #expect(throws: PlaylistRefreshService.RefreshError.notLinked) {
            _ = try await service.refresh(playlistID: playlist.id!)
        }
    }
}
