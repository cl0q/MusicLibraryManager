import Foundation
import Testing
@testable import MLM

/// A folder row of Folders (or an album card) dropped on the Queue column stands for its listed
/// tracks, like on the player (IMP-107, D-FOLD-FOLDER-TO-QUEUE): Play Next at the top, Add to
/// Queue elsewhere. The expansion itself is `FolderDragExpansion` / `AlbumDragExpansion` (faked
/// here — they need a whole open library).
@Suite("QueueFolderDropTests")
@MainActor
struct QueueFolderDropTests {
    private let folder = TrackDragItem.folder("House/Warm-up", libraryId: "lib", folderFilePath: nil, sort: nil)

    @Test func aFolderBecomesItsTracksInFolderOrderAroundPlainTracks() async {
        let rows = await TrackDragPayload.expandedQueueRows(
            [TrackDragItem(trackId: 5, libraryId: "lib"), folder],
            container: DependencyContainer.shared,
            expandFolders: { items in
                items.flatMap { item in
                    item.isFolder ? [11, 12, 13].map { TrackDragItem(trackId: $0, libraryId: "lib") } : [item]
                }
            })
        #expect(rows.map(\.trackId) == [5, 11, 12, 13])
    }

    @Test func anAlbumCardIsExpandedTooAndNeverLeavesATrackZeroRow() async {
        let rows = await TrackDragPayload.expandedQueueRows(
            [.album(9, libraryId: "lib")], container: DependencyContainer.shared,
            expandAlbums: { _ in [TrackDragItem(trackId: 21, libraryId: "lib"), TrackDragItem(trackId: 22, libraryId: "lib")] })
        #expect(rows.map(\.trackId) == [21, 22])

        // Unexpanded (a library that is not open): nothing is queued, not a row for track 0.
        let none = await TrackDragPayload.expandedQueueRows(
            [.album(9, libraryId: "lib"), folder], container: DependencyContainer.shared,
            expandFolders: { $0 }, expandAlbums: { $0 })
        #expect(none.isEmpty)
    }

    @Test func plainTracksPassThroughUntouched() async {
        var folderCalls = 0
        let rows = await TrackDragPayload.expandedQueueRows(
            [TrackDragItem(trackId: 1, libraryId: "lib"), TrackDragItem(trackId: 2, libraryId: "lib")],
            container: DependencyContainer.shared,
            expandFolders: { folderCalls += 1; return $0 })
        #expect(rows.map(\.trackId) == [1, 2])
        #expect(folderCalls == 0)
    }

    @Test func theExpandedRowsAreQueuedAtTheDropPosition() async throws {
        let files = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let vm = PlaybackViewModel(audioPlayer: SilentAudioPlayer(), environment: env.environment,
                                   previewPlayer: { SilentAudioPlayer() }, previewSchedule: { _, _ in })
        func local(_ id: Int64) -> Track {
            var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
            t.id = id
            t.organizedPath = files.file("\(id).m4a")
            t.duration = 200
            return t
        }
        let playing = local(1)
        await vm.playTrack(playing, queue: [playing])
        let undo = UndoCenter(statusBar: StatusBarCenter())
        let rows = await TrackDragPayload.expandedQueueRows(
            [folder], container: DependencyContainer.shared,
            expandFolders: { _ in [2, 3].map { TrackDragItem(trackId: $0, libraryId: nil) } })
        let task = QueueEditCommands.drop(rows, at: QueueDropTarget.position(.top), playback: vm, undo: undo,
                                          tracks: { ids in ids.map(local) })
        await task?.value
        #expect(vm.queueSnapshot.upcoming.map(\.id) == [2, 3], "Play Next in folder order")
        #expect(undo.stepCount == 1)
    }
}
