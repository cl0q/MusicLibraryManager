import Foundation
import Testing
@testable import MLM

// W1-1 review round: S10 (history), S11 (All Tracks visibility), S4 (drive loss).

@Suite("Shell navigation history")
@MainActor
struct ShellNavigationHistoryTests {
    @Test func forwardHistoryBelongsToItsDestination() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(1))
        nav.goBack()
        #expect(nav.canGoForward)

        nav.select(.folders)
        #expect(!nav.canGoForward, "Folders has no forward history of its own")
        nav.push(.genre("Techno"))
        nav.goBack()
        #expect(nav.canGoForward)

        nav.select(.allPlaylists)
        #expect(nav.canGoForward)
        nav.goForward()
        #expect(nav.path == [.playlist(1)])

        nav.select(.folders)
        nav.goForward()
        #expect(nav.path == [.genre("Techno")])
    }

    @Test func removingAPlaylistClearsItFromPathsAndForwardStacks() {
        let nav = NavigationModel(selection: .allPlaylists)
        nav.push(.playlist(5))
        nav.goBack()
        #expect(nav.canGoForward)

        nav.select(.playlist(5))
        nav.push(.genre("Techno"))
        nav.goBack()
        nav.select(.folders)

        nav.removePlaylist(5)
        nav.select(.allPlaylists)
        #expect(!nav.canGoForward, "Forward to a deleted playlist is gone")
        nav.select(.playlist(5))
        #expect(nav.path.isEmpty)
        #expect(!nav.canGoForward, "The deleted playlist's own history is gone")
    }

    @Test func removingASyncProfileClearsItsHistory() {
        let nav = NavigationModel(selection: .syncProfile(3))
        nav.push(.genre("Techno"))
        nav.push(.genre("Techno"))
        nav.goBack()
        nav.select(.folders)
        nav.removeSyncProfile(3)
        nav.select(.syncProfile(3))
        #expect(nav.path.isEmpty)
        #expect(!nav.canGoForward)
    }

    @Test func allTracksIsVisibleOnlyAtItsRoot() {
        let nav = NavigationModel()
        #expect(nav.isAllTracksVisible)
        nav.push(.genre("Techno"))
        #expect(!nav.isAllTracksVisible, "A route pushed over All Tracks hides it")
        nav.goBack()
        nav.select(.folders)
        #expect(!nav.isAllTracksVisible)
    }
}

@Suite("Shell drive loss")
@MainActor
struct ShellDriveLossTests {
    @Test func resumeIsOfferedOnlyAfterADriveCausedPause() {
        let drive = DriveLossPlayback()
        var paused = false
        let message = drive.driveDidDisconnect(volumeName: "Lexxar", isPlaying: true, position: "1:12") { paused = true }
        #expect(paused)
        #expect(message == "“Lexxar” was disconnected — playback paused at 1:12.")
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.offersResume == true)
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.offersResume == false, "Offered once")
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.message == "“Lexxar” connected.")
    }

    @Test func nothingPlayingMeansNoPauseAndNoResume() {
        let drive = DriveLossPlayback()
        var paused = false
        #expect(drive.driveDidDisconnect(volumeName: "Lexxar", isPlaying: false, position: "0:00") { paused = true } == nil)
        #expect(!paused)
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.offersResume == false)
    }

    @Test func playbackChangingForAnotherReasonDropsTheResume() {
        let drive = DriveLossPlayback()
        _ = drive.driveDidDisconnect(volumeName: "Lexxar", isPlaying: true, position: "1:00") {}
        drive.playbackDidChange(isPlaying: false)
        #expect(drive.pausedByDriveLoss, "Our own pause doesn't count")
        drive.playbackDidChange(isPlaying: true)
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.offersResume == false)

        _ = drive.driveDidDisconnect(volumeName: "Lexxar", isPlaying: true, position: "1:00") {}
        drive.trackDidChange()
        #expect(drive.driveDidConnect(volumeName: "Lexxar")?.offersResume == false)
    }

    @Test func tryAgainWordingWhileStillAway() {
        #expect(LibraryDriveState.stillNotConnectedMessage("Lexxar") == "“Lexxar” is still not connected.")
    }
}
