import Foundation
import Testing
@testable import MLM

/// W5-1b: Copy ▸ Link, Share…, the Dock without the open library, no MLM Help item, Show Tips
/// Again and the rule of when a tip may show (G29–G33).
@Suite("W5GapCommandsTests")
@MainActor
struct W5GapCommandsTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Menu bar

    @Test func shareAndShowTipsAgainAreWiredAndMLMHelpIsGone() throws {
        #expect(!MenuCommand.share.isPending && !MenuCommand.showTipsAgain.isPending)
        #expect(MenuCommand.items(in: .help).map(\.title) == ["Keyboard Shortcuts", "Show Tips Again"], "IMP-116")
        let help = try source("MLM/App/Commands/HelpCommands.swift")
        #expect(!help.contains(".mlmHelp") && help.contains("MLMTips.showAgain()"))
    }

    @Test func copySubmenuOffersLinkAndTrackMenuOffersShare() throws {
        let track = try source("MLM/App/Commands/TrackCommands.swift")
        #expect(track.contains("Button(\"Link\") { TrackCommandActions.copyLinks(tracks()) }"))
        #expect(track.contains("TrackShareItem("))
    }

    @Test func copyLinksPutsTheSourcePagesOnThePasteboardLines() {
        var web = Track(artist: "A", album: "", title: "T", format: "m4a", originalPath: "https://soundcloud.com/a/t")
        web.id = 1
        var file = Track(artist: "A", album: "", title: "U", format: "m4a", originalPath: "/tmp/u.m4a")
        file.id = 2
        #expect([web, file].compactMap { TrackLinks.sourceURL($0)?.absoluteString } == ["https://soundcloud.com/a/t"])
    }

    // MARK: Share…

    private func local(_ id: Int64, organized: String) -> Track {
        var track = Track(artist: "A", album: "", title: "T\(id)", format: "m4a", originalPath: "/o/\(id).m4a")
        track.id = id
        track.organizedPath = organized
        return track
    }

    @Test func shareOffersLocalTracksOnly() {
        let downloaded = local(1, organized: "A/T1.m4a")
        var remote = Track(artist: "A", album: "", title: "R", format: "m4a", originalPath: "https://x.example/r")
        remote.id = 2
        #expect(TrackShare.reachable([downloaded, remote], offlineVolumePath: nil).map(\.id) == [1])
        #expect(TrackShare.reachable([remote], offlineVolumePath: nil).isEmpty)
    }

    @Test func shareExplainsWhyItIsOff() {
        #expect(TrackShare.disabledReason(count: 1, unreachable: 0) == "Can’t share — the track isn’t downloaded.")
        #expect(TrackShare.disabledReason(count: 3, unreachable: 0) == "Can’t share — none of the tracks is downloaded.")
        #expect(TrackShare.disabledReason(count: 2, unreachable: 2) == "Can’t share — the library’s drive is not connected.")
        #expect(TrackShare.disabledReason(count: 0, unreachable: 0) == "Select tracks to share.")
    }

    @Test func shareSitsAfterCopyInTheContextMenuModel() {
        #expect(TrackMenuModel.shareItem(reachableLocal: 2, unreachable: 0) == .share(enabled: true))
        #expect(TrackMenuModel.shareItem(reachableLocal: 0, unreachable: 1) == .share(enabled: false))
        #expect(TrackMenuModel.shareItem(reachableLocal: 0, unreachable: 0) == nil, "nothing to share, nothing offered")
    }

    // MARK: Dock

    @Test func dockListsOnlyTheOtherLibraries() {
        let open = DockMenuModel.RecentLibrary(title: "Main", url: URL(fileURLWithPath: "/tmp/a/../main.mlibm"), isAvailable: true)
        let other = DockMenuModel.RecentLibrary(title: "Archive", url: URL(fileURLWithPath: "/tmp/archive.mlibm"), isAvailable: true)
        let shown = DockMenuBuilder.otherLibraries([open, other], excluding: URL(fileURLWithPath: "/tmp/main.mlibm"))
        #expect(shown == [other])
        #expect(DockMenuBuilder.otherLibraries([open, other], excluding: nil) == [open, other])
        let model = DockMenuModel(nowPlaying: nil, isPlaying: false, recents: DockMenuBuilder.otherLibraries([open], excluding: open.url))
        #expect(!model.items.contains { $0.title == "Open Recent" }, "no other library: no Open Recent")
    }

    // MARK: Tips

    @Test func aTipNeverShowsWhileASheetIsOpenOrAPreviewPlays() {
        #expect(MLMTipGate.isQuiet(sheetOpen: false, previewPlaying: false))
        #expect(!MLMTipGate.isQuiet(sheetOpen: true, previewPlaying: false))
        #expect(!MLMTipGate.isQuiet(sheetOpen: false, previewPlaying: true))
        #expect(!MLMTipGate.isQuiet(sheetOpen: true, previewPlaying: true))
    }

    @Test func theMonitorReportsChangesOnly() {
        var sheet = false
        var preview = false
        var heard: [Bool] = []
        let monitor = MLMTipMonitor(sheetOpen: { sheet }, previewPlaying: { preview }, apply: { heard.append($0) })
        monitor.refresh()
        monitor.refresh()
        sheet = true
        monitor.refresh()
        preview = true
        monitor.refresh()
        sheet = false
        preview = false
        monitor.refresh()
        #expect(heard == [true, false, true])
    }

    @Test func theThreeTipsAreNamedAsDesigned() {
        let tips = try? source("MLM/Services/Tips/MLMTips.swift")
        for title in ["Press Space to preview", "Drag tracks onto a playlist", "Edit several tracks at once"] {
            #expect(tips?.contains("Text(\"\(title)\")") == true, Comment(rawValue: title))
        }
        let sources = ["Sidebar/SidebarView.swift": "DragToPlaylistTip", "TrackList/SelectionBar.swift": "EditSeveralTip",
                       "TrackList/TrackListTable.swift": "PreviewTip"]
        for (file, tip) in sources {
            #expect((try? source("MLM/Views/" + file))?.contains("as? \(tip)") == true, "\(tip) is shown in \(file)")
        }
        #expect((try? source("MLM/App/MLMApp.swift"))?.contains("MLMTips.configure()") == true)
    }
}
