import Testing
import Foundation
@testable import MLM

/// W5-1a G12–G18, G40: page sentences, VoiceOver traits, cover panel messages, and the
/// keyboard reorder of a playlist (IMP-117).
@Suite("W5GapPagesTests")
struct W5GapPagesTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Sentences from the audit table (G12, G14, G18)")
    func sentences() throws {
        #expect(try source("MLM/Views/Library/LibraryView.swift").contains(
            "Import music from a folder, or import a playlist from SoundCloud, YouTube or Spotify. You can also drop files here."))
        #expect(try source("MLM/Views/Review/ReviewView.swift").contains(
            "No duplicates, tag conflicts or album suggestions are waiting. Run a scan after importing more music."))
        let maintenance = try source("MLM/Views/Settings/MaintenanceView.swift")
        #expect(maintenance.contains("Maintenance that reads audio files can’t run until it is."))
        #expect(maintenance.contains("Applies to the next run."))
        #expect(!maintenance.contains("Jobs that") && !maintenance.contains("next job"))
    }

    @Test("Sync picker rows tell VoiceOver what is selected (G16, G17)")
    func pickerTraits() throws {
        let text = try source("MLM/Views/Sync/SyncProfileSheets.swift")
        #expect(text.contains(".accessibilityAddTraits(row.isSelected ? .isSelected : [])"))
        #expect(text.contains(".accessibilityLabel(row.playlist.name)"))
        #expect(text.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
    }

    @Test("Both album cover panels carry a message line (G40)")
    func coverPanelMessages() throws {
        for path in ["MLM/Views/Albums/AlbumDetailView.swift", "MLM/Views/Albums/AlbumInfoSheet.swift"] {
            #expect(try source(path).contains(".fileDialogMessage(\"Choose an image for the cover of “"), "\(path)")
        }
    }

    // MARK: G13 — ⌥↑ / ⌥↓ in Manual order

    private func plan(_ selected: [Int64], _ step: Int, order: [Int64] = [1, 2, 3, 4, 5],
                      manual: Bool = true, filtered: Bool = false) -> PlaylistDropPlan? {
        PlaylistKeyboardMove.plan(selected: selected, playlistOrder: order, step: step,
                                  isPlaylistOrder: manual, isFiltered: filtered)
    }

    @Test("One row moves one place up or down as a reorder")
    func movesOnePlace() throws {
        let up = try #require(plan([3], -1))
        #expect(up.kind == .reorder)
        #expect(up.apply(to: [1, 2, 3, 4, 5]) == [1, 3, 2, 4, 5])
        let down = try #require(plan([3], 1))
        #expect(down.apply(to: [1, 2, 3, 4, 5]) == [1, 2, 4, 3, 5])
        let toEnd = try #require(plan([4], 1))
        #expect(toEnd.apply(to: [1, 2, 3, 4, 5]) == [1, 2, 3, 5, 4])
    }

    @Test("A block moves together; a gathered selection stays in playlist order")
    func movesBlocks() throws {
        #expect(try #require(plan([3, 2], -1)).apply(to: [1, 2, 3, 4, 5]) == [2, 3, 1, 4, 5])
        #expect(try #require(plan([2, 3], 1)).apply(to: [1, 2, 3, 4, 5]) == [1, 4, 2, 3, 5])
        #expect(try #require(plan([2, 4], 1)).apply(to: [1, 2, 3, 4, 5]) == [1, 3, 5, 2, 4])
    }

    @Test("Nothing at the ends; off while sorted, filtered or with no selection")
    func disabledCases() {
        #expect(plan([1], -1) == nil)
        #expect(plan([5], 1) == nil)
        #expect(plan([1, 2], -1) == nil)
        #expect(plan([3], -1, manual: false) == nil)
        #expect(plan([3], 1, filtered: true) == nil)
        #expect(plan([], 1) == nil)
        #expect(plan([99], 1) == nil)
    }

    @Test("The playlist table wires the keys through the undoable placement")
    func wired() throws {
        let text = try source("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(text.contains("PlaylistKeyboardMove.plan("))
        #expect(text.contains("edits.placeTracks(plan"))
        #expect(text.contains("press.modifiers == .option"))
    }
}
