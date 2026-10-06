import Testing
import Foundation
@testable import MLM

/// W5-1a G8–G10: the Queue and Review track menus follow the catalogue.
@Suite("W5GapMenuTests")
@MainActor
struct W5GapMenuTests {
    private func track(_ id: Int64, albumID: Int64? = nil) -> Track {
        var track = Track(artist: "Artist", album: "Album", title: "Song", format: "m4a", originalPath: "A/original.m4a")
        track.id = id
        track.organizedPath = "A/song.m4a"
        track.albumId = albumID
        return track
    }

    private func menu(_ tracks: [Track], _ context: TrackMenuContext) -> TrackMenuModel {
        TrackMenuModel.make(subject: TrackMenuSubject(rows: TrackRowBuilder.build(tracks), live: .idle), context: context)
    }

    @Test("Review version rows are Get Info and Show in All Tracks only (G10)")
    func reviewVersionRow() {
        let context = TrackMenuContext(container: .reviewGroup(key: "k"), canActivate: true,
                                       canRemoveFromContainer: false, canAddToSyncProfile: false)
        let items = menu([track(1, albumID: 4)], context).items
        #expect(items.contains(.getInfo))
        #expect(!items.contains { if case .goToAlbum = $0 { true } else { false } })
        #expect(!items.contains { if case .goToArtist = $0 { true } else { false } })
    }

    @Test("Queue Next rows: Get Info, Go to Album, Go to Artist, Find Similar, Show in (G8)")
    func nextRowFindSimilar() {
        let context = TrackMenuContext(container: .queue, canActivate: true, canRemoveFromContainer: true,
                                       canAddToSyncProfile: true, queueRows: .next(contextName: "“Warm-up”"))
        let info = menu([track(1, albumID: 4)], context).sections.first { $0.contains(.getInfo) }
        #expect(info == [.getInfo, .goToAlbum(4), .goToArtist("Artist"), .findSimilar, .showInContext(name: "“Warm-up”")])
        #expect(!menu([track(1), track(2)], context).items.contains(.findSimilar))
    }

    @Test("Queue History rows: Find Similar after Go to Album (G9)")
    func historyRowFindSimilar() {
        let context = TrackMenuContext(container: .queue, canActivate: true, canRemoveFromContainer: false,
                                       canAddToSyncProfile: true, queueRows: .history(canPlay: true))
        let info = menu([track(1, albumID: 4)], context).sections.first { $0.contains(.getInfo) }
        #expect(info == [.getInfo, .goToAlbum(4), .findSimilar])
    }
}
