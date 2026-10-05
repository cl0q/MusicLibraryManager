import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MLM

/// The drag payload (W2-H, UC-DND-01/02): internal ids under the declared types, the legacy
/// shape still read, `public.file-url` only for a local, reachable file, never across libraries.
@Suite("Drag payloads")
@MainActor
struct DragPayloadTests {
    // MARK: Types

    @Test func theTypesAreTheDeclaredOnes() throws {
        #expect(UTType.draggedTracks.identifier == "com.ilczuk.mlm.track")
        #expect(UTType.draggedPlaylist.identifier == "com.ilczuk.mlm.playlist")
        #expect(UTType.legacyTrackDrag.identifier == "com.musiclibrary.trackdrag")
        #expect(UTType.trackDrag == .legacyTrackDrag)
        // Declared in the Info.plist the app bundle gets (exported: ours; imported: legacy).
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/run.sh"), encoding: .utf8)
        let exported = try #require(script.range(of: "<key>UTExportedTypeDeclarations</key>"))
        let imported = try #require(script.range(of: "<key>UTImportedTypeDeclarations</key>"))
        let exportedPart = script[exported.upperBound..<imported.lowerBound]
        #expect(exportedPart.contains("<string>com.ilczuk.mlm.track</string>"))
        #expect(exportedPart.contains("<string>com.ilczuk.mlm.playlist</string>"))
        #expect(script[imported.upperBound...].contains("<string>com.musiclibrary.trackdrag</string>"))
    }

    // MARK: Codable round trips

    @Test func aTrackItemRoundTripsItsIdsButNotItsPath() throws {
        let entry = UUID()
        let item = TrackDragItem(trackId: 7, sourcePlaylistId: 3, queueEntryId: entry, libraryId: "lib-A",
                                 filePath: "/Volumes/Lexxar/Music/a.m4a")
        let data = try JSONEncoder().encode(item)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("Lexxar"), "the path leaves MLM only as the file URL")
        let decoded = try JSONDecoder().decode(TrackDragItem.self, from: data)
        #expect(decoded == TrackDragItem(trackId: 7, sourcePlaylistId: 3, queueEntryId: entry, libraryId: "lib-A"))
    }

    @Test func theLegacyShapeStillDecodes() throws {
        // `TrackDragData` (track lists) and `QueueRowDrag` (queue rows) before W2-H.
        let table = Data(#"{"trackId":9,"sourcePlaylistId":2}"#.utf8)
        let fromTable = try JSONDecoder().decode(TrackDragItem.self, from: table)
        #expect(fromTable.trackId == 9 && fromTable.sourcePlaylistId == 2 && fromTable.libraryId == nil)
        let entry = UUID()
        let queue = try JSONEncoder().encode(QueueRowDrag(trackId: 4, sourcePlaylistId: nil, queueEntryId: entry))
        let fromQueue = try JSONDecoder().decode(TrackDragItem.self, from: queue)
        #expect(fromQueue.trackId == 4 && fromQueue.queueEntryId == entry)
        // …and the queue reads the new shape.
        let new = try JSONEncoder().encode(TrackDragItem(trackId: 5, queueEntryId: entry, libraryId: "lib"))
        #expect(try JSONDecoder().decode(QueueRowDrag.self, from: new) == QueueRowDrag(trackId: 5, sourcePlaylistId: nil, queueEntryId: entry))
    }

    @Test func aPlaylistItemRoundTrips() throws {
        let item = PlaylistDragItem(playlistId: 12, libraryId: "lib")
        #expect(try JSONDecoder().decode(PlaylistDragItem.self, from: JSONEncoder().encode(item)) == item)
    }

    // MARK: On the pasteboard (NSItemProvider, as a drag writes it)

    @Test func aLocalTrackOffersIdsAndItsFileURL() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DragPayloadTests-\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider()
        provider.register(TrackDragItem(trackId: 1, libraryId: "lib", filePath: file.path))
        let types = provider.registeredTypeIdentifiers
        #expect(types.first == UTType.draggedTracks.identifier, "inside MLM the ids win")
        #expect(types.contains(UTType.fileURL.identifier))
        // Nothing else: no plain text, no source link.
        #expect(Set(types).isSubset(of: [UTType.draggedTracks.identifier, UTType.url.identifier, UTType.fileURL.identifier]))

        let url = try await Self.load(URL.self, from: provider)
        #expect(url.standardizedFileURL.path == file.standardizedFileURL.path)
        let back = try await Self.load(TrackDragItem.self, from: provider)
        #expect(back.trackId == 1 && back.libraryId == "lib")
    }

    @Test func aTrackWithoutAFileOffersNoFileURL() {
        let provider = NSItemProvider()
        provider.register(TrackDragItem(trackId: 2, libraryId: "lib", filePath: nil))
        #expect(provider.registeredTypeIdentifiers == [UTType.draggedTracks.identifier])
    }

    @Test func aLegacyDragIsReadAsATrackItem() async throws {
        let provider = NSItemProvider()
        provider.register(LegacyTrackDrag(trackId: 8, sourcePlaylistId: 1, queueEntryId: nil))
        let item = try await Self.load(TrackDragItem.self, from: provider)
        #expect(item == TrackDragItem(trackId: 8, sourcePlaylistId: 1, libraryId: nil))
    }

    @Test func thePayloadKeepsDragOrderAndCountsTracksWithoutFiles() {
        let payload = TrackDragPayload(items: [
            TrackDragItem(trackId: 3, sourcePlaylistId: 9, libraryId: "L", filePath: "/m/3.mp3"),
            TrackDragItem(trackId: 1, sourcePlaylistId: 9, libraryId: "L", filePath: nil),
            TrackDragItem(trackId: 2, sourcePlaylistId: 9, libraryId: "L", filePath: "/m/2.mp3"),
            TrackDragItem(trackId: 3, sourcePlaylistId: 9, libraryId: "L", filePath: "/m/3.mp3"),
        ])
        #expect(payload.trackIDs == [3, 1, 2])
        #expect(payload.sourcePlaylistID == 9)
        #expect(payload.exportedFiles.urls.map(\.path) == ["/m/3.mp3", "/m/2.mp3", "/m/3.mp3"])
        #expect(payload.exportedFiles.leftOut == 1)
    }

    @Test func aDragNeverCrossesLibraries() {
        let ours = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "A")])
        let theirs = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "A"), TrackDragItem(trackId: 2, libraryId: "B")])
        let legacy = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: nil)])
        #expect(!ours.crossesLibraries(current: "A"))
        #expect(theirs.crossesLibraries(current: "A"))
        #expect(!legacy.crossesLibraries(current: "A"), "one library per process: an id-less item is this one's")
        #expect(!theirs.crossesLibraries(current: nil), "no library open: nothing to compare")
    }

    // MARK: File-URL export rules (no disk access)

    @Test func onlyALocalReachableTrackHasAFile() {
        let root = "/Volumes/Lexxar/Music"
        func path(_ organized: String?, _ availability: TrackAvailability, root: String? = root, offline: String? = nil) -> String? {
            TrackDragContext.filePath(organizedPath: organized, availability: availability,
                                      libraryRoot: root, offlineVolumePath: offline)
        }
        #expect(path("Artist/Album/01.m4a", .local) == "/Volumes/Lexxar/Music/Artist/Album/01.m4a")
        #expect(path("Artist/01.m4a", .notDownloaded) == nil)
        #expect(path("Artist/01.m4a", .downloading) == nil)
        #expect(path("Artist/01.m4a", .fileMissing) == nil)
        #expect(path("Artist/01.m4a", .failed(reason: "x", date: .distantPast, attempts: 1)) == nil)
        #expect(path(nil, .local) == nil)
        #expect(path("", .local) == nil)
        #expect(path("Artist/01.m4a", .local, root: nil) == nil, "a relative path needs the library folder")
        // Drive away: nothing on it leaves MLM.
        #expect(path("Artist/01.m4a", .local, offline: "/Volumes/Lexxar") == nil)
        #expect(path("/Volumes/Lexxar/Other/01.m4a", .local, offline: "/Volumes/Lexxar") == nil)
        // A file on another disk is still reachable.
        #expect(path("/Volumes/Other/01.m4a", .local, offline: "/Volumes/Lexxar") == "/Volumes/Other/01.m4a")
        #expect(path("/Users/o/Music/01.m4a", .local) == "/Users/o/Music/01.m4a")
    }

    @Test func theContextBuildsItemsFromPersistedState() {
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: "/orig/T.m4a")
        track.id = 42
        track.organizedPath = "A/B/T.m4a"
        let context = TrackDragContext(libraryID: "lib", libraryRoot: "/Music", offlineVolumePath: nil)
        let item = context.item(for: track, sourcePlaylistID: 5)
        #expect(item == TrackDragItem(trackId: 42, sourcePlaylistId: 5, libraryId: "lib", filePath: "/Music/A/B/T.m4a"))
        var unsaved = track
        unsaved.id = nil
        #expect(context.item(for: unsaved) == nil)
        var notDownloaded = track
        notDownloaded.organizedPath = nil
        #expect(context.item(for: notDownloaded)?.filePath == nil)
    }

    // MARK: Out of MLM a drag copies

    @Test func dragsOutOfMLMCopyAndNeverMove() throws {
        let configuration = try String(contentsOf: Self.repoRoot.appendingPathComponent("MLM/Views/TrackList/TrackListConfiguration.swift"), encoding: .utf8)
        let outside = configuration.components(separatedBy: "operationsOutsideApp: .init(").dropFirst()
        #expect(outside.count == 2)
        for part in outside {
            #expect(part.hasPrefix("allowCopy: true, allowMove: false, allowDelete: false)"))
        }
        // Every drag source applies it.
        for file in ["MLM/Views/TrackList/TrackListTable.swift", "MLM/Views/Player/PlayerBar.swift"] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(".dragConfiguration(TrackDragConfiguration."), "\(file)")
        }
    }

    // MARK: -

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func load<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            _ = provider.loadTransferable(type: type) { continuation.resume(with: $0) }
        }
    }
}
