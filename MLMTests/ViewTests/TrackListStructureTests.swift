import Foundation
import Testing
@testable import MLM

/// Structural guarantees of the shared track table (W2-A): no disk probes on the row paths
/// (UC-TABLE-20, N13), one table component for every track list, the keys and modifiers the
/// contract names.
@Suite("TrackListStructureTests")
struct TrackListStructureTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(in directory: String) throws -> [String] {
        let url = projectRoot.appendingPathComponent(directory)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".swift") }
            .map { "\(directory)/\($0)" }
    }

    /// Every source a row's drawing, scrolling, sorting or selection can reach.
    private var rowPathSources: [String] {
        get throws {
            try swiftFiles(in: "MLM/Views/TrackList") + swiftFiles(in: "MLM/Views/Library") + [
                "MLM/Views/Playlists/PlaylistTable.swift",
                "MLM/Views/Shared/StatusChip.swift",
                "MLM/Views/Shared/TrackMetadataPresentation.swift",
                "MLM/ViewModels/LibraryViewModel.swift",
                "MLM/ViewModels/PlaylistDetailViewModel.swift",
                "MLM/Models/TrackAvailability.swift",
                "MLM/Models/Track.swift",
                "MLM/App/Commands/TrackSelection.swift",
            ]
        }
    }

    @Test func noDiskProbesOnTheRowPaths() throws {
        for path in try rowPathSources {
            let text = try source(path)
            #expect(!text.contains("fileExists"), "\(path) probes the disk (UC-TABLE-20)")
            #expect(!text.contains("FileManager"), "\(path) uses FileManager (UC-TABLE-20)")
        }
        // The old per-load mapper is gone.
        #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("MLM/Views/Shared/TrackPresentationAvailability.swift").path))
    }

    @Test func oneTableComponentForEveryTrackList() throws {
        #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("MLM/Views/Library/TrackTable.swift").path))
        #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("MLM/Views/Library/LibraryTable.swift").path))
        for path in [
            "MLM/Views/Library/LibraryView.swift",
            "MLM/Views/Playlists/PlaylistTable.swift",
            "MLM/Views/Search/SearchResultsView.swift",
        ] {
            #expect(try source(path).contains("TrackListTable("), "\(path) hosts the shared table")
        }
        let queue = try source("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(queue.components(separatedBy: "TrackListTable(").count - 1 == 3)
        #expect(queue.contains(".frame(height: 64)"), "now playing shows exactly one row")
        // Only the shared component builds a track `Table`.
        for path in ["MLM/Views/Library/LibraryView.swift", "MLM/Views/Playlists/PlaylistTable.swift",
                     "MLM/Views/Search/SearchResultsView.swift", "MLM/Views/Queue/PlaybackQueueView.swift"] {
            let text = try source(path)
            #expect(!text.contains("Table(of:") && !text.contains("TableColumn("), "\(path) builds its own table")
        }
    }

    @Test func tableUsesTheNativeContract() throws {
        let table = try source("MLM/Views/TrackList/TrackListTable.swift")
        #expect(table.contains("Table(of: TrackRow.self, selection: $model.selection, sortOrder: sortOrder, columnCustomization: $columnCustomization)"))
        #expect(table.contains(".contextMenu(forSelectionType: Int64.self)"))
        #expect(table.contains("primaryAction:"))
        #expect(table.contains(".onDeleteCommand("))
        #expect(table.contains(".onCopyCommand"))
        #expect(table.contains("SceneStorage"))
        #expect(table.contains(".focusedValue(\\.trackSelection"))
        #expect(table.contains(".focusedValue(\\.trackTableViewOptions"))
        #expect(table.contains(".statusBarText("))
        #expect(!table.contains("ProgressView()"), "no spinner in the table (UC-TABLE-09)")
        // Space is the focused table's preview key (W2-C, UC-KIT-11) — handled with
        // `.onKeyPress` on the table, never a key equivalent (UC-KEY-37).
        #expect(!table.contains(".keyboardShortcut(.space"), "Space is never a key equivalent")
        #expect(table.contains(".modifier(TrackListPreviewKeys(actions: actions))"))
        let keys = try source("MLM/Views/TrackList/TrackListPreviewKeys.swift")
        #expect(keys.contains(".onKeyPress(keys: [.space, .escape, .leftArrow, .rightArrow]"))
        #expect(!keys.contains("togglePlayPause"), "Space never means Play/Pause (§10 Q1)")
        let cell = try source("MLM/Views/TrackList/TrackCell.swift")
        #expect(cell.contains(".typeSelectEquivalent(row.title)"))
        #expect(cell.contains("speaker.wave.2.fill"))
    }

    @Test func rebuiltPrimitivesUseNoThemeTokens() throws {
        for path in try swiftFiles(in: "MLM/Views/TrackList") + [
            "MLM/Views/Shared/StatusChip.swift", "MLM/Views/Shared/TrackMetadataPresentation.swift",
            "MLM/Views/Library/EnergyBars.swift", "MLM/Views/Library/DanceabilitySteps.swift",
            "MLM/Views/Library/LibraryView.swift", "MLM/Views/Library/TrackContextMenu.swift",
            "MLM/Views/Playlists/PlaylistTable.swift",
        ] {
            let text = try source(path)
            #expect(!text.contains(".mlm") && !text.contains("MLMFont"), "\(path) uses a deprecated theme token (UC-COLOR-03)")
            #expect(!text.contains("Color(red:"), "\(path) invents a colour")
        }
    }

    /// The context menu shows keys (UC-CM-06); each is the menu bar's key for the same command
    /// or the focused list's own ↩ / ⌫ — never a new shortcut (UC-KEY-39).
    @Test func contextMenuKeysMirrorTheMenuBar() throws {
        // No plain ↩ or ⌫: while the menu is open they could fire Play / Remove instead of the
        // highlighted item (W2-A review). Only modified keys that mirror menu-bar items.
        let allowed: [String: MenuShortcut?] = [
            ".keyboardShortcut(.return, modifiers: .option)": MenuCommand.playNext.shortcut,
            ".keyboardShortcut(\"n\", modifiers: [.command, .shift])": MenuCommand.newPlaylistFromSelection.shortcut,
            ".keyboardShortcut(\"i\", modifiers: .command)": MenuCommand.toggleInfo.shortcut,
            ".keyboardShortcut(\"d\", modifiers: .command)": MenuCommand.download.shortcut,
            ".keyboardShortcut(\"r\", modifiers: [.command, .shift])": MenuCommand.showInFinder.shortcut,
            ".keyboardShortcut(.delete, modifiers: .command)": MenuCommand.removeFromLibrary.shortcut,
        ]
        #expect(allowed[".keyboardShortcut(.return, modifiers: .option)"] == MenuShortcut(key: .returnKey, modifiers: .option))
        #expect(allowed[".keyboardShortcut(\"n\", modifiers: [.command, .shift])"] == .cmd("n", .shift))
        #expect(allowed[".keyboardShortcut(\"i\", modifiers: .command)"] == .cmd("i"))
        #expect(allowed[".keyboardShortcut(\"d\", modifiers: .command)"] == .cmd("d"))
        #expect(allowed[".keyboardShortcut(\"r\", modifiers: [.command, .shift])"] == .cmd("r", .shift))
        #expect(allowed[".keyboardShortcut(.delete, modifiers: .command)"] == .cmd(.delete))
        let menu = try source("MLM/Views/TrackList/TrackMenu.swift")
        for line in menu.components(separatedBy: "\n") where line.contains(".keyboardShortcut(") {
            let call = line.trimmingCharacters(in: .whitespaces)
            #expect(allowed.keys.contains(call), "\(call) is not a key of the menu bar or the focused list")
        }
        #expect(!menu.contains(".keyboardShortcut(.return, modifiers: [])"))
        #expect(!menu.contains(".keyboardShortcut(.delete, modifiers: [])"))
        // Enabled items carry no empty help.
        #expect(!menu.contains(".help(\"\")") && !menu.contains("? \"\" :"))
        // ⌫ in the table and Track ▸ Remove from ‹Container› act on the shown selection (S5).
        let table = try source("MLM/Views/TrackList/TrackListTable.swift")
        #expect(table.contains("{ remove(Set(model.selectedRows().map(\\.id))) }"))
        #expect(table.contains("{ ids in remove(Set(model.selectedRows(ids).map(\\.id))) }"))
        #expect(table.contains(".focusedValue(\\.trackSelection, visible ? selection(summary: summary) : nil)"))
    }

    @Test func playlistRemovalIsUndoableAndAddToPlaylistGoesThroughTheShell() throws {
        let actions = try source("MLM/Views/TrackList/TrackListActions.swift")
        #expect(actions.contains("undo.perform("))
        #expect(actions.contains("playlists.removeEntries("))
        #expect(actions.contains("playlists.restoreEntries("))
        #expect(actions.contains("TrackCommandActions.addToPlaylist(playlistID, tracks: rows.map(\\.track), shell: shell)"))
        #expect(actions.contains("TrackCommandActions.newPlaylistFromSelection(rows.map(\\.track), shell: shell)"))
        #expect(!actions.contains("appendTracks("))
    }
}
