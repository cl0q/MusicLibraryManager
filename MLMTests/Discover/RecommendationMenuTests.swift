import Foundation
import Testing
@testable import MLM

/// The menu of a held recommendation (CM-REC, V-INBOX.N07) and the `Find Similar` item (W3-DISC-A).
@Suite("RecommendationMenuTests")
struct RecommendationMenuTests {
    private func track(_ id: Int64, path: String? = "N/x.m4a") -> Track {
        var track = Track(artist: "Artist", album: "", title: "Song \(id)", format: "m4a", originalPath: "/o/\(id).m4a")
        track.id = id
        track.organizedPath = path
        track.downloadStatus = path == nil ? nil : "2026-10-01T10:00:00Z"
        return track
    }

    private let extras = TrackMenuExtras(
        addTo: [TrackMenuExtra(id: "keep", title: "Keep")],
        info: [TrackMenuExtra(id: "goToSeed", title: "Go to Seed Track")],
        remove: [TrackMenuExtra(id: "dismiss", title: "Dismiss")])

    private func menu(_ tracks: [Track], context: TrackMenuContext, live: TrackTableLiveState = .idle) -> TrackMenuModel {
        TrackMenuModel.make(subject: TrackMenuSubject(rows: TrackRowBuilder.build(tracks), live: live), context: context)
    }

    private func recommendationContext(extras: TrackMenuExtras) -> TrackMenuContext {
        TrackMenuContext(container: .recommendations, canActivate: true, canRemoveFromContainer: true,
                         canAddToSyncProfile: false, extras: extras)
    }

    @Test func oneRecommendationHasExactlyTheDesignedMenu() {
        let model = menu([track(1)], context: recommendationContext(extras: extras))
        #expect(model.sections == [
            [.preview(enabled: true)],
            [.extra(TrackMenuExtra(id: "keep", title: "Keep")), .keepAndAddToPlaylist],
            [.extra(TrackMenuExtra(id: "goToSeed", title: "Go to Seed Track")), .findSimilar],
            [.showInFinder(enabled: true), .copy(filePath: true, link: false)],
            [.extra(TrackMenuExtra(id: "dismiss", title: "Dismiss"))],
        ])
        let titles = "\(model.items)"
        for absent in ["play(", "playNext", "addToQueue", "addToSyncProfile", "removeFromLibrary", "getInfo", "goToArtist"] {
            #expect(!titles.contains(absent), "a held recommendation has no \(absent)")
        }
    }

    @Test func severalRecommendationsKeepTheVerdictsAndNoSimilarOrPreview() {
        let model = menu([track(1), track(2)], context: recommendationContext(extras: TrackMenuExtras(
            addTo: [TrackMenuExtra(id: "keep", title: "Keep")], remove: [TrackMenuExtra(id: "dismiss", title: "Dismiss")])))
        #expect(model.sections.first == [.countHeader(2)])
        #expect(!model.items.contains(.findSimilar))
        #expect(model.items.contains(.keepAndAddToPlaylist))
        #expect(!model.items.contains { if case .preview = $0 { true } else { false } })
    }

    @Test func dismissIsDisabledWithTheDriveAway() {
        var disabled = extras
        disabled.remove = [TrackMenuExtra(id: "dismiss", title: "Dismiss", isEnabled: false)]
        let model = menu([track(1)], context: recommendationContext(extras: disabled),
                         live: TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar"))
        #expect(model.items.contains(.extra(TrackMenuExtra(id: "dismiss", title: "Dismiss", isEnabled: false))))
        #expect(model.items.contains(.showInFinder(enabled: false)))
    }

    @Test func findSimilarIsOfferedForOneLibraryTrackAndNeverDeletesInSimilar() {
        let library = TrackMenuContext(container: .library, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
        #expect(menu([track(1)], context: library).items.contains(.findSimilar))
        #expect(!menu([track(1), track(2)], context: library).items.contains(.findSimilar))
        let similar = TrackMenuContext(container: .similar(trackID: 9), canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
        let items = menu([track(1)], context: similar).items
        #expect(items.contains(.findSimilar))
        #expect(!items.contains { if case .removeFromLibrary = $0 { true } else { false } }, "V-SIMILAR.N07")
        let review = TrackMenuContext(container: .reviewGroup(key: "k"), canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: false)
        #expect(!menu([track(1)], context: review).items.contains(.findSimilar))
    }

    @Test func theSelectionSummaryNeverOffersRemoveFromLibraryHere() {
        for container in [TrackListContainer.recommendations, .similar(trackID: 1)] {
            let rows = TrackRowBuilder.build([track(1)])
            let summary = TrackSelectionSummary(rows: rows, container: container, live: .idle)
            let state = TrackCommandState(summary: summary, capabilities: TrackListCapabilities(TrackCommandTarget()), isDownloadBusy: false)
            #expect(!state.canRemoveFromLibrary)
        }
    }
}
