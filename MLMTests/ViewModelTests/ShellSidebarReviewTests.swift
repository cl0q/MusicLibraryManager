import Foundation
import Testing
@testable import MLM

// W1-1 review round: B1, S5, S7, relative time.

@Suite("Shell sidebar reload and states")
@MainActor
struct ShellSidebarReloadTests {
    private func playlist(_ id: Int64, _ name: String = "P", sourceId: Int64? = nil) -> Playlist {
        var p = Playlist(id: nil, name: name, category: "regular", isLiked: 0, isSmart: 0, isPinned: 0)
        p.id = id
        p.sourceId = sourceId
        return p
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "mlm.tests.sidebar.reload.\(UUID().uuidString)")!
    }

    @Test func reloadReportsPlaylistsThatDisappeared() async {
        let model = SidebarModel(defaults: defaults())
        let first = await model.reloadPlaylists(fetch: { [playlist(1), playlist(2)] })
        #expect(first.isEmpty)
        let second = await model.reloadPlaylists(fetch: { [playlist(1)] })
        #expect(second == [2])
        #expect(model.playlists.compactMap(\.id) == [1])
    }

    @Test func aStaleOverlappingReloadIsDropped() async {
        let model = SidebarModel(defaults: defaults())
        let gate = ManualSleeper()
        let older = Task {
            await model.reloadPlaylists(fetch: {
                await gate.sleep(.seconds(1))
                return [self.playlist(1)]
            })
        }
        await gate.waitForPending(1)
        let newer = Task {
            await model.reloadPlaylists(fetch: {
                await gate.sleep(.seconds(2))
                return [self.playlist(1), self.playlist(7, "Untitled Playlist")]
            })
        }
        await gate.waitForPending(2)

        await gate.releaseLast()
        _ = await newer.value
        #expect(model.playlists.compactMap(\.id) == [1, 7])

        await gate.releaseAll()
        let staleRemoved = await older.value
        #expect(staleRemoved.isEmpty, "A superseded reload must not report the new playlist as removed")
        #expect(model.playlists.compactMap(\.id) == [1, 7], "…nor bring back the stale list")
    }

    @Test func linkedPlaylistShowsItsSourceSignInState() {
        #expect(SidebarModel.signInService(forSourceName: "soundcloud") == .soundcloud)
        #expect(SidebarModel.signInService(forSourceName: "spotify") == .spotify)
        #expect(SidebarModel.signInService(forSourceName: "youtube") == nil)
        #expect(SidebarModel.playlistSecondLine(sourceName: "soundcloud", unusableSignIns: [.soundcloud])
                == "SoundCloud sign-in expired")
        #expect(SidebarModel.playlistSecondLine(sourceName: "soundcloud", unusableSignIns: []) == nil,
                "Healthy playlists are one line")
        #expect(SidebarModel.playlistSecondLine(sourceName: nil, unusableSignIns: [.soundcloud]) == nil)
    }

    @Test func syncPageAndSelectionAlwaysAgree() {
        #expect(SyncProfilePageAgreement.reconcile(pageProfileID: 1, selectedProfileID: 1, profileIDs: [1, 2]) == .agree)
        #expect(SyncProfilePageAgreement.reconcile(pageProfileID: 1, selectedProfileID: 2, profileIDs: [1, 2]) == .followSelection(2),
                "A duplicate / created profile became the selection: the page follows")
        #expect(SyncProfilePageAgreement.reconcile(pageProfileID: 1, selectedProfileID: nil, profileIDs: [1, 2]) == .selectPage)
        #expect(SyncProfilePageAgreement.reconcile(pageProfileID: 1, selectedProfileID: 9, profileIDs: [1, 2]) == .selectPage,
                "A selection that no longer exists yields to the page")
    }

    @Test func syncedTimeIsRelative() {
        let now = Date()
        let text = SyncProfileRowState.synced(now.addingTimeInterval(-7200)).text(relativeTo: now)
        let expected = Date.AnchoredRelativeFormatStyle(anchor: now.addingTimeInterval(-7200), presentation: .named, unitsStyle: .wide).format(now)
        #expect(text == "Synced \(expected)")
    }
}
