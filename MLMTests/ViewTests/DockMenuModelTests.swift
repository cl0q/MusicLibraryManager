import Testing
import Foundation
@testable import MLM

/// W1-2 Dock menu (UC-DOCK-01, M-DOCK; C22 `Not playing`).
@Suite("Dock menu (W1-2)")
struct DockMenuModelTests {

    private let recents = [
        DockMenuModel.RecentLibrary(title: "Laptop Subset", url: URL(fileURLWithPath: "/tmp/a.mlibm"), isAvailable: true),
        DockMenuModel.RecentLibrary(title: "Archive 2019 — Not connected", url: URL(fileURLWithPath: "/tmp/b.mlibm"), isAvailable: false),
    ]

    @Test func idleShowsNotPlayingAndDisablesTransport() {
        let model = DockMenuModel(nowPlaying: nil, isPlaying: false, recents: [])
        #expect(model.items.map(\.title) == ["Not playing", "Play", "Next", "Previous"])
        #expect(model.items[0].action == nil && !model.items[0].isEnabled, "the header is a disabled line")
        #expect(model.items.dropFirst().allSatisfy { !$0.isEnabled }, "nothing to play, pause or skip")
    }

    @Test func playingShowsTitleAndArtistAndPause() {
        let model = DockMenuModel(nowPlaying: (title: "Glass Circuit", artist: "Overmono"), isPlaying: true, recents: [])
        #expect(model.items.map(\.title) == ["Glass Circuit — Overmono", "Pause", "Next", "Previous"])
        #expect(model.items.dropFirst().allSatisfy { $0.isEnabled })
        #expect(model.items.dropFirst().map(\.action) == [.playPause, .next, .previous])
    }

    @Test func pausedTitleFollowsState() {
        let model = DockMenuModel(nowPlaying: (title: "Glass Circuit", artist: ""), isPlaying: false, recents: [])
        #expect(model.items[0].title == "Glass Circuit")
        #expect(model.items[1].title == "Play")
    }

    @Test func openRecentListsOtherLibrariesWithTheirState() {
        let model = DockMenuModel(nowPlaying: nil, isPlaying: false, recents: recents)
        let tail = Array(model.items.dropFirst(4))
        #expect(tail[0].isSeparator)
        #expect(tail[1].title == "Open Recent" && tail[1].action == nil && !tail[1].isEnabled)
        #expect(tail[2].title == "Laptop Subset" && tail[2].isEnabled)
        #expect(tail[2].action == .openLibrary(URL(fileURLWithPath: "/tmp/a.mlibm")))
        #expect(tail[3].title == "Archive 2019 — Not connected" && !tail[3].isEnabled, "unreachable libraries are disabled")
    }

    @Test func noMiniPlayerOrMenuBarExtra() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("MLM/App/MLMApp.swift"), encoding: .utf8)
        #expect(!app.contains("MenuBarExtra"), "UC-KIT-32")
        let delegate = try String(contentsOf: root.appendingPathComponent("MLM/App/AppDelegate.swift"), encoding: .utf8)
        #expect(delegate.contains("func applicationDockMenu(_ sender: NSApplication) -> NSMenu?"))
        #expect(delegate.contains("func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        false"),
                "closing the main window does not quit (UC-WIN-01)")
    }
}
