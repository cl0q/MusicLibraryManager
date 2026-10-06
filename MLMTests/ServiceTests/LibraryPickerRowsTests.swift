import Testing
import Foundation
@testable import MLM

/// W3-LAUNCH: the picker's rows (V-PICKER) — order, state words of UC-STATE §15.1, the old
/// install, unlisted problems — and `Remove from List` / `Undo` on the registry (A0 D5: only
/// the list changes). Pure; no filesystem.
@Suite("Library picker rows (W3-LAUNCH)")
struct LibraryPickerRowsTests {

    private func entry(_ id: String, _ path: String, opened: TimeInterval?) -> LibraryRegistry.Entry {
        LibraryRegistry.Entry(libraryId: id, path: path, name: id.uppercased(),
                              lastOpenedAt: opened.map { Date(timeIntervalSince1970: $0) })
    }

    private var registry: LibraryRegistry {
        LibraryRegistry(libraries: [
            entry("a", "/tmp/A.mlibm", opened: 10),
            entry("b", "/Volumes/Lexxar/MLM/B.mlibm", opened: 30),
            entry("c", "/tmp/C.mlibm", opened: 20),
            entry("d", "/tmp/D.mlibm", opened: nil),
        ], lastActiveLibraryId: "b")
    }

    private func availability(_ url: URL) -> LibraryAvailability {
        switch url.lastPathComponent {
        case "B.mlibm": return .notConnected
        case "C.mlibm": return .notFound
        default: return .available
        }
    }

    @Test func rowsCarryTheirStateInWordsMostRecentFirst() {
        let rows = LibraryPickerRows.build(
            registry: registry, legacyDatabase: URL(fileURLWithPath: "/tmp/music_library.db"),
            mismatches: ["/tmp/D.mlibm": "ids"], availability: availability)
        #expect(rows.map(\.id) == ["b", "c", "a", "d", "legacy"])
        #expect(rows.map(\.stateText) == [
            "Not connected — on “Lexxar”", "Not found", nil,
            "Can’t be opened — the file and its database don’t match", nil,
        ])
        #expect(rows.map(\.canOpen) == [false, false, true, false, true])
        #expect(rows.map(\.openRefusal) == [
            "Can’t open — not connected", "Can’t open — not found", nil, "Can’t open — doesn’t match its database", nil,
        ])
        #expect(rows.last?.listedName == "Main Library (needs setup)")
        #expect(rows[0].explanation?.hasPrefix("The library file is on “Lexxar”, which isn’t connected.") == true)
        #expect(rows[1].explanation == "The library file isn’t where MLM last found it. If you moved it, locate it. If you deleted it, remove it from this list — nothing else is removed.")
    }

    @Test func unlistedProblemsComeFirstAndInitialSelectionFollowsTheFocus() {
        let stray = URL(fileURLWithPath: "/tmp/Stray.mlibm")
        let rows = LibraryPickerRows.build(
            registry: registry, legacyDatabase: nil,
            unlisted: [UnlistedLibraryProblem(url: stray, name: "Stray", state: .mismatch(details: "x"))],
            availability: availability)
        #expect(rows.first?.kind == .unlisted)
        #expect(LibraryPickerRows.initialSelection(in: rows, focus: URL(fileURLWithPath: "/tmp/C.mlibm")) == "c")
        // Without a focus: the most recent library that can be opened.
        #expect(LibraryPickerRows.initialSelection(in: rows, focus: nil) == "a")
    }

    /// S3: an interrupted setup replaces the old install's row, with its own words.
    @Test func anInterruptedSetupReplacesTheOldInstallsRow() {
        let journal = URL(fileURLWithPath: "/tmp/adoption-journal.json")
        let rows = LibraryPickerRows.build(
            registry: LibraryRegistry(), legacyDatabase: URL(fileURLWithPath: "/tmp/music_library.db"),
            interruptedSetup: InterruptedSetup(name: "Main Library", journal: journal, details: "journalUnreadable"),
            availability: availability)
        #expect(rows.map(\.id) == ["setup-interrupted"])
        #expect(rows[0].listedName == "Main Library (setup interrupted)")
        #expect(rows[0].openRefusal == "Can’t open — setup interrupted")
        #expect(rows[0].state == .setupInterrupted(details: "journalUnreadable"))
    }

    /// N6: a library on a volume that isn't mounted is never read.
    @Test func factsAreNotReadFromAnUnmountedVolume() {
        #expect(LibraryPickerFacts.read(databaseAt: URL(fileURLWithPath: "/Volumes/MLMTestNoSuchVolume-\(UUID().uuidString)/X.mlibm/music_library.db")) == nil)
    }

    @Test func factsCaption() {
        #expect(LibraryPickerFacts(trackCount: 12_935, libraryRoot: "/Volumes/Lexxar/Music").caption(isLegacy: false)
                == "\(12_935.formatted(.number)) tracks · library folder on “Lexxar”")
        #expect(LibraryPickerFacts(trackCount: 1, libraryRoot: "/Users/me/Music").caption(isLegacy: false)
                == "1 track · library folder on this Mac")
        #expect(LibraryPickerFacts(trackCount: 4, libraryRoot: nil).caption(isLegacy: true)
                == "4 tracks · not yet a library file")
    }

    @Test func removeAndReinsertRestoreTheListExactly() throws {
        var list = registry
        let original = list
        let removed = list.remove(libraryId: "b")
        let removal = try #require(removed)
        #expect(list.entry(withId: "b") == nil)
        #expect(list.lastActiveLibraryId == nil)
        #expect(removal.wasLastActive && removal.index == 1)
        list.reinsert(removal)
        #expect(list == original)
        let none = list.remove(libraryId: "nope")
        #expect(none == nil)
    }
}
