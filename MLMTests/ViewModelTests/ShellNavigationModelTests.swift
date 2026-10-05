import Foundation
import SwiftUI
import Testing
@testable import MLM

@Suite("Shell navigation model")
@MainActor
struct ShellNavigationModelTests {

    @Test func startsAtAllTracksWithoutHistory() {
        let nav = NavigationModel()
        #expect(nav.selection == .allTracks)
        #expect(nav.path.isEmpty)
        #expect(!nav.canGoBack)
        #expect(!nav.canGoForward)
    }

    @Test func numberedRowsAreTheSixFixedDestinationsInShortcutOrder() {
        #expect(SidebarDestination.numbered == [.allTracks, .albums, .genres, .folders, .discover, .review])
        #expect(SidebarDestination.numbered.map(\.numberKey) == ["1", "2", "3", "4", "5", "6"])
        #expect(SidebarDestination.allPlaylists.numberKey == nil)
        #expect(SidebarDestination.playlist(3).numberKey == nil)
        #expect(SidebarDestination.syncProfile(3).numberKey == nil)
    }

    @Test func sectionsHoldExactlyTheDesignedRows() {
        #expect(SidebarDestination.librarySection.map(\.fixedTitle) == ["All Tracks", "Albums", "Genres", "Folders"])
        #expect(SidebarDestination.inboxSection.map(\.fixedTitle) == ["Discover", "Review"])
        #expect(SidebarSectionID.allCases.map(\.title) == ["Library", "Inbox", "Playlists", "Sync"])
    }

    @Test func pushBackForwardForAPlaylistFromAllPlaylists() {
        let nav = NavigationModel()
        nav.select(.allPlaylists)
        nav.push(.playlist(7))
        #expect(nav.currentRoute == .playlist(7))
        #expect(nav.canGoBack)
        #expect(!nav.canGoForward)

        nav.goBack()
        #expect(nav.path.isEmpty)
        #expect(nav.canGoForward)

        nav.goForward()
        #expect(nav.path == [.playlist(7)])
        #expect(!nav.canGoForward)
    }

    @Test func pushingSomethingNewClearsForward() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(1))
        nav.goBack()
        #expect(nav.canGoForward)
        nav.push(.playlist(2))
        #expect(!nav.canGoForward)
        #expect(nav.path == [.playlist(2)])
    }

    @Test func eachDestinationKeepsItsOwnPathWhenLeftAndReentered() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(4))
        nav.select(.folders)
        #expect(nav.path.isEmpty)
        #expect(!nav.canGoBack, "Back never crosses sidebar destinations")
        nav.select(.allPlaylists)
        #expect(nav.path == [.playlist(4)])
    }

    @Test func reselectingTheCurrentDestinationPopsToRootAndKeepsForward() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(4))
        nav.push(.sources)
        nav.select(.allPlaylists)
        #expect(nav.path.isEmpty)
        nav.goForward()
        #expect(nav.path == [.playlist(4)])
        nav.goForward()
        #expect(nav.path == [.playlist(4), .sources])
    }

    @Test func systemPopThroughTheStackBindingFeedsForward() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(1))
        nav.push(.playlist(2))
        nav.setPath([.playlist(1)])
        #expect(nav.canGoForward)
        nav.goForward()
        #expect(nav.path == [.playlist(1), .playlist(2)])

        nav.setPath([.sources])
        #expect(!nav.canGoForward, "A replaced path is a new push")
    }

    @Test func deletingAPlaylistLeavesItsDestinationAndDropsItsRoutes() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(9))
        nav.push(.playlist(10))
        nav.select(.playlist(9))
        nav.removePlaylist(9)
        #expect(nav.selection == .allPlaylists)
        #expect(nav.path == [.playlist(10)])
    }

    @Test func deletingASyncProfileLeavesItsDestination() {
        let nav = NavigationModel(selection: .syncProfile(2))
        nav.removeSyncProfile(2)
        #expect(nav.selection == .allTracks)
        let other = NavigationModel(selection: .folders)
        other.removeSyncProfile(2)
        #expect(other.selection == .folders)
    }

    @Test func titleNamesTheVisiblePlace() {
        let names = PlaceNames(
            playlist: { $0 == 5 ? "Warm-up" : nil },
            syncProfile: { $0 == 1 ? "iPod Classic" : nil },
            track: { $0 == 8 ? "Glass Circuit" : nil }
        )
        let nav = NavigationModel()
        #expect(nav.title(names: names) == "All Tracks")
        nav.select(.playlist(5))
        #expect(nav.title(names: names) == "Warm-up")
        nav.select(.syncProfile(1))
        #expect(nav.title(names: names) == "iPod Classic")
        nav.select(.syncProfile(99))
        #expect(nav.title(names: names) == "Sync Profile")
        nav.select(.allPlaylists)
        #expect(nav.title(names: names) == "All Playlists")
        nav.push(.playlist(5, showFailedTracks: true))
        #expect(nav.title(names: names) == "Warm-up")
        nav.push(.similar(trackID: 8))
        #expect(nav.title(names: names) == "Similar to “Glass Circuit”")
    }

    @Test func driveBannerAppliesOnlyToPlacesThatListTracks() {
        let nav = NavigationModel()
        #expect(nav.currentPlaceListsTracks)
        nav.select(.allPlaylists)
        #expect(!nav.currentPlaceListsTracks)
        nav.push(.playlist(1))
        #expect(nav.currentPlaceListsTracks)
        nav.push(.sources)
        #expect(!nav.currentPlaceListsTracks)
        #expect(!SidebarDestination.albums.listsTracks)
        #expect(SidebarDestination.syncProfile(1).listsTracks)
    }

    @Test func routesAreCodable() throws {
        let routes: [DetailRoute] = [.playlist(1), .playlist(2, showFailedTracks: true), .album(3), .genre("Techno"), .similar(trackID: 4), .sources]
        let data = try JSONEncoder().encode(routes)
        #expect(try JSONDecoder().decode([DetailRoute].self, from: data) == routes)
    }
}

@Suite("Shell trailing column")
@MainActor
struct ShellTrailingColumnTests {
    private func defaults() -> UserDefaults {
        let suite = "mlm.tests.trailing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsClosedInInfoMode() {
        let state = TrailingColumnState(defaults: defaults())
        #expect(!state.isPresented)
        #expect(state.mode == .info)
    }

    @Test func eachToggleOpensItsModeSwitchesAndClosesInItsMode() {
        let state = TrailingColumnState(defaults: defaults())
        state.toggle(.info)
        #expect(state.isShowing(.info))
        state.toggle(.queue)
        #expect(state.isShowing(.queue))
        #expect(!state.isShowing(.info), "Info and Queue are never visible together")
        state.toggle(.queue)
        #expect(!state.isPresented)
        #expect(state.mode == .queue)
    }

    @Test func openStateAndModeAreRemembered() {
        let store = defaults()
        let first = TrailingColumnState(defaults: store)
        first.toggle(.queue)
        let second = TrailingColumnState(defaults: store)
        #expect(second.isShowing(.queue))
    }
}

@Suite("Shell sidebar model")
@MainActor
struct ShellSidebarModelTests {
    @Test func untitledPlaylistNamesAreNumberedWhenTaken() {
        #expect(SidebarModel.untitledPlaylistName(existing: []) == "Untitled Playlist")
        #expect(SidebarModel.untitledPlaylistName(existing: ["Untitled Playlist"]) == "Untitled Playlist 2")
        #expect(SidebarModel.untitledPlaylistName(existing: ["untitled playlist", "Untitled Playlist 2"]) == "Untitled Playlist 3")
    }

    @Test func sectionExpansionPersistsPerLibrary() {
        let suite = "mlm.tests.sidebar.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        let model = SidebarModel(defaults: store)
        model.useLibrary(id: "lib-a")
        #expect(SidebarSectionID.allCases.allSatisfy { model.isExpanded($0) })
        model.setExpanded(.playlists, false)

        let reopened = SidebarModel(defaults: store)
        reopened.useLibrary(id: "lib-a")
        #expect(!reopened.isExpanded(.playlists))
        #expect(reopened.isExpanded(.sync))

        reopened.useLibrary(id: "lib-b")
        #expect(reopened.isExpanded(.playlists), "Another library has its own state")
    }

    @Test func syncRowStateFollowsTheDesignedPrecedenceAndWords() {
        let now = Date()
        let syncing = SyncProfileRowState.make(isSyncing: true, processed: 86, total: 214, isReachable: false, pendingAdds: 3, lastSynced: now)
        #expect(syncing.text(relativeTo: now) == "Syncing 86 of 214")
        #expect(syncing.progress != nil)

        let offline = SyncProfileRowState.make(isSyncing: false, processed: 0, total: 0, isReachable: false, pendingAdds: 12, lastSynced: now)
        #expect(offline.text(relativeTo: now) == "Not connected")

        let toAdd = SyncProfileRowState.make(isSyncing: false, processed: 0, total: 0, isReachable: true, pendingAdds: 12, lastSynced: now)
        #expect(toAdd.text(relativeTo: now) == "12 to add")

        let synced = SyncProfileRowState.make(isSyncing: false, processed: 0, total: 0, isReachable: true, pendingAdds: 0, lastSynced: now.addingTimeInterval(-7200))
        #expect(synced.text(relativeTo: now).hasPrefix("Synced "))
        #expect(synced.progress == nil)

        let fresh = SyncProfileRowState.make(isSyncing: false, processed: 0, total: 0, isReachable: true, pendingAdds: nil, lastSynced: nil)
        #expect(fresh.text(relativeTo: now) == "Connected")
    }

    @Test func driveWordingIsVerbatim() {
        #expect(LibraryDriveState.volumeName(fromVolumePath: "/Volumes/Lexxar") == "Lexxar")
        #expect(LibraryDriveState.volumeName(fromVolumePath: nil) == nil)
        #expect(LibraryDriveState.bannerSubject("Lexxar") == "“Lexxar” is not connected.")
        #expect(LibraryDriveState.bannerConsequence == "You can browse, edit and queue downloads; playback and file actions are paused.")
        #expect(LibraryDriveState.footerText("Lexxar") == "“Lexxar” — not connected")
        #expect(LibraryDriveState(volumeName: nil, isConnected: false).isOffline == false, "A boot-volume library is never offline")
        #expect(LibraryDriveState(volumeName: "Lexxar", isConnected: false).isOffline)
    }

    @Test func countsUseSeparatorsAndPlurals() {
        #expect(StatusBarText.tracks(1) == "1 track")
        #expect(StatusBarText.playlists(0) == "0 playlists")
        #expect(StatusBarText.tracks(12_935) == "\(12_935.formatted(.number)) tracks")
        // W3-ACT: import result words come from Activity's result sentence.
        #expect(ActivityResult(counts: [.init(.done, 35, "imported"), .init(.failed, 2, "failed")]).statusSentence
                == "35 imported, 2 failed")
    }
}
