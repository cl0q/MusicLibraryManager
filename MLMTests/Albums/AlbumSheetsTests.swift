import AppKit
import Foundation
import GRDB
import Testing
@testable import MLM

// W4-2b: Edit Album Info, Merge with Another Album, Use a Track from the Library, the shared
// album picker (IMP-093…095). Temporary databases; an undo center on its own manager; a fake tag
// writer; nothing touches a file.

typealias SheetLibrary = AlbumListingTests.Library

@MainActor
private struct SheetEnv {
    let lib: SheetLibrary
    let manager: UndoManager
    let undo: UndoCenter
    let status: StatusBarCenter
    let edits: ShellEdits
    let tagEdit: TrackTagEdit

    init(writesEnabled: Bool = false, reachable: Bool = true) throws {
        let lib = try SheetLibrary()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let window = ShellWindowModels(navigation: NavigationModel(),
                                       sidebar: SidebarModel(defaults: UserDefaults(suiteName: "AlbumSheetsTests-\(UUID().uuidString)")!),
                                       statusBar: status)
        let db = lib.db
        let tagRepository = TrackTagRepository(database: db)
        let queue = TagWriteQueue(dependencies: .init(
            repository: { tagRepository }, libraryRoot: { "/lib" }, isEnabled: { writesEnabled },
            writer: NullTagWriter(), statusBar: { nil }))
        let tagEdit = TrackTagEdit(dependencies: .init(
            repository: { tagRepository }, writesEnabled: { writesEnabled }, isLibraryFolderReachable: { reachable },
            volumeName: { "Lexxar" }, queue: queue, tracksDidChange: { _ in }), undo: nil)
        self.lib = lib
        self.manager = manager
        self.undo = undo
        self.status = status
        self.tagEdit = tagEdit
        edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { PlaylistRepository(database: db) }, syncProfiles: { SyncRepository(database: db) },
                syncProfileDidChange: { _ in }, albumTracks: { lib.joins }, albums: { lib.albums }),
            undo: undo, window: window)
    }

    func undoStep() async {
        manager.undo()
        await undo.waitUntilIdle()
    }

    func redoStep() async {
        manager.redo()
        await undo.waitUntilIdle()
    }

    func trackRow(_ id: Int64) async throws -> (album: String, albumArtist: String, year: Int?, genre: String?, albumID: Int64?) {
        try await lib.db.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT album, album_artist, year, genre, album_id FROM tracks WHERE id = ?", arguments: [id]))
            return (row["album"], row["album_artist"], row["year"], row["genre"], row["album_id"])
        }
    }

    func pendingWrites() async throws -> [String] {
        try await lib.db.read { db in try String.fetchAll(db, sql: "SELECT fields FROM pending_tag_writes ORDER BY track_id") }
    }
}

// MARK: - The picker

@Suite("AlbumPickingTests")
@MainActor
struct AlbumPickingTests {
    private func candidate(_ id: Int64, _ title: String, artist: String = "Overmono", year: Int? = nil, tracks: Int = 3) -> AlbumCandidate {
        AlbumCandidate(album: Album(id: id, artist: artist, albumArtist: artist, title: title,
                                    titleNormalized: AlbumKey.normalize(title), year: year, coverPath: nil, variantOf: nil, variantKind: nil),
                       trackCount: tracks)
    }

    @Test func theSameKeyComesFirstThenTitleContainsThenTheSameArtist() {
        let reference = AlbumPickReference(title: "Low Season", albumArtist: "Overmono")
        let list = [
            candidate(1, "Zebra", artist: "Overmono"),
            candidate(2, "Low Season Remixes", artist: "Various Artists"),
            candidate(3, "low-season", artist: "overmono"),
            candidate(4, "Apple", artist: "Bicep"),
            candidate(5, "Low Season (Deluxe)", artist: "Overmono"),
        ]
        let ranked = AlbumPickRanking.rank(list, for: reference, query: "")
        #expect(ranked.map(\.id) == [3, 5, 2, 1, 4], "same key; title contains (by title); same artist; the rest")
        #expect(AlbumPickRanking.tier(of: list[2].album, for: reference) == .sameKey)
        #expect(AlbumPickRanking.tier(of: list[1].album, for: reference) == .titleContains)
        #expect(AlbumPickRanking.tier(of: list[0].album, for: reference) == .sameArtist)
        #expect(AlbumPickRanking.tier(of: list[3].album, for: reference) == .other)
    }

    @Test func theSearchTextNarrowsByTitleOrArtistIgnoringCaseAndAccents() {
        let reference = AlbumPickReference(title: "Low Season", albumArtist: "Overmono")
        let list = [candidate(1, "Café Del Mar", artist: "Various Artists"), candidate(2, "Low Season"), candidate(3, "Other", artist: "Bicep")]
        #expect(AlbumPickRanking.rank(list, for: reference, query: "cafe").map(\.id) == [1])
        #expect(AlbumPickRanking.rank(list, for: reference, query: "BICEP oth").map(\.id) == [3])
        #expect(AlbumPickRanking.rank(list, for: reference, query: "zzz").isEmpty)
    }

    @Test func aTrackReferenceWithoutATitleRanksByArtist() {
        let reference = AlbumPickReference(title: "", albumArtist: "Bicep")
        let list = [candidate(1, "Isles", artist: "Bicep"), candidate(2, "Aardvark", artist: "Lone")]
        #expect(AlbumPickRanking.rank(list, for: reference, query: "").map(\.id) == [1, 2])
    }

    @Test func theDetailLineSaysArtistYearAndTracks() {
        #expect(candidate(1, "Low Season", year: 2020, tracks: 4).detailLine == "Overmono · 2020 · 4 tracks")
        #expect(candidate(1, "Low Season Bonus", tracks: 1).detailLine == "Overmono · no year · 1 track")
    }

    @Test func candidatesAreBaseAlbumsWithListedTracksWithoutTheGroupOfTheAlbum() async throws {
        let lib = try SheetLibrary()
        let (here, _) = try await lib.album("Low Season", count: 2)
        let (other, _) = try await lib.album("Other", count: 1)
        let (edition, _) = try await lib.album("Low Season Deluxe", count: 2)
        let (empty, _) = try await lib.album("Empty", count: 0)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE albums SET variant_of = ?, variant_kind = 'Deluxe' WHERE id = ?", arguments: [here, edition])
        }
        let all = try await lib.albums.pickCandidates()
        #expect(Set(all.map(\.id)) == [here, other], "editions and albums without a listed track are not offered")
        let without = try await lib.albums.pickCandidates(excludingGroupOf: here)
        #expect(without.map(\.id) == [other])
        #expect(!without.contains { $0.id == empty })
        #expect(try await lib.albums.pickCandidates(excludingGroupOf: edition).map(\.id) == [other], "an edition's group is its base and siblings")
    }

    @Test func chosenAlbumReplacesTheSuggestionOfANoMatchRowAndWritesNothingUntilAccept() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        let id = try await AlbumSuggestionDecisionsTests.track(env, "So U Know", suggestion: nil)
        try await env.repository.upsert([AlbumSuggestionRow.looked(up: id, candidates: [])])
        let track = try await env.db.read { db in try #require(try Track.fetchOne(db, key: id)) }
        let row = try #require(try await env.repository.row(trackID: id))
        let item = AlbumSuggestionItem(track: track, row: row)
        let album = Album(id: 9, artist: "Overmono", albumArtist: "Overmono", title: "Good Lies", titleNormalized: "goodlies", year: 2023,
                          coverPath: nil, variantOf: nil, variantKind: nil)
        #expect(await env.decisions.choose(album: album, for: item))
        let after = try #require(try await env.repository.row(trackID: id))
        #expect(after.status == .pending)
        #expect(after.suggestion.albumTitle == "Good Lies" && after.suggestion.albumArtist == "Overmono" && after.suggestion.year == 2023)
        #expect(after.suggestion.source == "Chosen by you" && after.suggestion.match == 100)
        let stored = try await AlbumSuggestionDecisionsTests.trackRow(env, id)
        #expect(stored.album == "" && stored.albumID == nil, "nothing is written until Accept")
    }

    @Test func theSuggestionItReplacesBecomesAnAlternativeAndTheChosenOneIsNotListedTwice() {
        let old = AlbumSuggestion(albumTitle: "Folder Name", source: "Folder name", match: 80)
        let same = AlbumSuggestion(albumTitle: "good  lies", albumArtist: "OVERMONO", source: "File name", match: 60)
        let row = AlbumSuggestionRow(trackID: 1, suggestion: old, alternatives: [same], status: .pending, decidedAt: nil)
        let album = Album(id: 9, artist: "Overmono", albumArtist: "Overmono", title: "Good Lies", titleNormalized: "goodlies", year: nil,
                          coverPath: nil, variantOf: nil, variantKind: nil)
        let next = AlbumSuggestionDecisions.row(row, choosing: album)
        #expect(next.suggestion.albumTitle == "Good Lies")
        #expect(next.alternatives == [old])
    }
}

// MARK: - Edit Album Info

@Suite("AlbumInfoEditTests")
@MainActor
struct AlbumInfoEditTests {
    private func album(_ title: String = "Low Season", artist: String = "Overmono", year: Int? = 2019) -> Album {
        Album(id: 1, artist: artist, albumArtist: artist, title: title, titleNormalized: AlbumKey.normalize(title), year: year,
              coverPath: nil, variantOf: nil, variantKind: nil)
    }

    private func track(_ artist: String, genre: String? = nil, year: Int? = nil) -> Track {
        var track = Track(artist: artist, album: "Low Season", title: "T", format: "flac", originalPath: "/x/\(UUID().uuidString)")
        track.genre = genre
        track.year = year
        return track
    }

    @Test func theFormStartsFromTheAlbumAndItsTracks() {
        let form = AlbumInfoForm(album: album(year: nil), tracks: [track("Overmono", genre: "Techno", year: 2019), track("Overmono", genre: "Techno", year: 2019), track("Lone", genre: "Ambient")])
        #expect(form.original == AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: 2019, genre: "Techno"))
        #expect(form.yearText == "2019" && form.genre == "Techno" && !form.isCompilation)
        #expect(form.problem == nil && !form.hasChanges)
    }

    @Test func compilationOnMakesTheArtistVariousArtistsAndOffPrefillsTheMajorityTrackArtist() {
        var form = AlbumInfoForm(album: album(), tracks: [track("Lone"), track("Lone"), track("Bicep")])
        form.setCompilation(true)
        #expect(form.albumArtist == "Various Artists" && form.isCompilation)
        #expect(form.values?.albumArtist == "Various Artists")
        form.albumArtist = "typed while disabled"
        #expect(form.values?.albumArtist == "Various Artists", "the toggle decides while it is on")
        form.setCompilation(false)
        #expect(form.albumArtist == "Lone" && !form.isCompilation)
        let starting = AlbumInfoForm(album: album(artist: "various artists"), tracks: [track("Bicep")])
        #expect(starting.isCompilation, "any case of Various Artists")
    }

    @Test func problemsAreSaidAndStopSave() {
        var form = AlbumInfoForm(album: album(), tracks: [])
        form.title = "  "
        #expect(form.problem == .emptyTitle && form.values == nil)
        #expect(AlbumInfoForm.sentence(for: .emptyTitle) == "Enter a title.")
        form.title = "Low Season"
        form.yearText = "19"
        #expect(form.problem == .badYear && !form.hasChanges)
        form.yearText = ""
        #expect(form.problem == nil && form.values?.year == nil && form.hasChanges, "an empty year clears it")
        form.yearText = "2019"
        form.albumArtist = " "
        #expect(form.problem == .emptyAlbumArtist)
    }

    @Test func onlyTheChangedFieldsAreTagEdits() {
        let original = AlbumInfoValues(title: "A", albumArtist: "X", year: 2019, genre: "Techno")
        var new = original
        #expect(AlbumInfoRules.changedFields(from: original, to: new).isEmpty)
        new.title = "B"
        new.genre = nil
        #expect(AlbumInfoRules.changedFields(from: original, to: new) == [.album, .genre])
        #expect(AlbumInfoRules.rowChanges(from: original, to: new))
        new = original
        new.genre = "House"
        #expect(!AlbumInfoRules.rowChanges(from: original, to: new), "the genre is a track tag only")
    }

    @Test func genresCompleteFromTheExistingNames() {
        let existing = ["Techno", "Tech House", "House", "Trance"]
        #expect(AlbumInfoRules.genreSuggestions(typed: "tec", existing: existing) == ["Techno", "Tech House"])
        #expect(AlbumInfoRules.genreSuggestions(typed: "techno", existing: existing).isEmpty, "the exact name needs no completion")
        #expect(AlbumInfoRules.genreSuggestions(typed: " ", existing: existing).isEmpty)
    }

    @Test func theFootnoteFollowsTheSettingAndTheDrive() {
        #expect(AlbumInfoText.footnote(writesTags: false, offlineVolume: "Lexxar") == nil)
        #expect(AlbumInfoText.footnote(writesTags: true, offlineVolume: nil)
            == "Saved to the library and, because “Write tags to files” is on in Settings ▸ Library, to the tags of the files.")
        #expect(AlbumInfoText.footnote(writesTags: true, offlineVolume: "Lexxar")?.hasSuffix("While “Lexxar” is not connected the tag changes wait in Activity.") == true)
        #expect(AlbumInfoText.subtitle(trackCount: 10) == "Applies to the album and its 10 tracks in the library.")
        #expect(AlbumInfoText.subtitle(trackCount: 1) == "Applies to the album and its 1 track in the library.")
    }

    @Test func saveIsOneStepForTheRowAndTheChangedTagsAndUndoRestoresBoth() async throws {
        let env = try SheetEnv()
        let (id, tracks) = try await env.lib.album("Low Season", year: 2019, count: 3, genre: "Techno")
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: 2019, genre: "Techno")
        var new = original
        new.title = "Low  Season (Remastered)"
        new.year = 2021
        let outcome = try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, tagEdit: env.tagEdit)
        #expect(outcome?.title == "Low  Season (Remastered)")
        let row = try #require(try await env.lib.albums.fetch(id: id))
        #expect(row.title == new.title && row.year == 2021 && row.titleNormalized == AlbumKey.normalize(new.title))
        for track in tracks {
            let stored = try await env.trackRow(track)
            #expect(stored.album == new.title && stored.year == 2021)
            #expect(stored.genre == "Techno" && stored.albumArtist == "Overmono" || stored.albumArtist == "", "unchanged fields are not written")
        }
        #expect(env.manager.undoMenuItemTitle == "Undo Edit Album Info")
        #expect(env.status.message?.text == "Edited “Low  Season (Remastered)”")
        #expect(env.undo.stepCount == 1, "one step for the row and every tag part")
        await env.undoStep()
        let back = try #require(try await env.lib.albums.fetch(id: id))
        #expect(back.title == "Low Season" && back.year == 2019 && back.titleNormalized == AlbumKey.normalize("Low Season"))
        for track in tracks {
            let stored = try await env.trackRow(track)
            #expect(stored.album == "Low Season" && stored.year == 2019)
        }
        await env.redoStep()
        #expect(try await env.lib.albums.fetch(id: id)?.title == new.title)
        #expect(try await env.trackRow(tracks[0]).album == new.title)
    }

    @Test func aTagEditRunsOnlyForTheFieldsThatChanged() async throws {
        let env = try SheetEnv(writesEnabled: true, reachable: false)
        let (id, tracks) = try await env.lib.album("Low Season", year: 2019, count: 2, genre: "Techno")
        try await env.lib.db.write { db in try db.execute(sql: "UPDATE tracks SET organized_path = 'Music/' || id || '.flac'") }
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: 2019, genre: "Techno")
        var new = original
        new.genre = "House"
        let outcome = try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, tagEdit: env.tagEdit, volumeName: "Lexxar")
        #expect(outcome?.waiting == 2)
        #expect(env.status.message?.text == "Edited “Low Season” · 2 tag changes waiting for “Lexxar”")
        #expect(try await env.trackRow(tracks[0]).genre == "House")
        #expect(try await env.lib.albums.fetch(id: id)?.title == "Low Season", "no row change for a genre edit")
        let pending = try await env.pendingWrites()
        #expect(pending.count == 2 && pending.allSatisfy { $0 == "genre" }, "only the genre is queued for the files")
    }

    @Test func nothingIsQueuedForFilesWhileWriteTagsToFilesIsOff() async throws {
        let env = try SheetEnv(writesEnabled: false)
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: nil, genre: nil)
        var new = original
        new.title = "Low Season 2"
        new.genre = "Techno"
        try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, tagEdit: env.tagEdit)
        #expect(try await env.trackRow(tracks[0]).album == "Low Season 2")
        #expect(try await env.pendingWrites().isEmpty, "the library changes, no file is queued")
    }

    @Test func aTitleAndArtistThatAnotherAlbumHasAreRefusedAndNothingChanges() async throws {
        let env = try SheetEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        _ = try await env.lib.album("Fabric Mix", count: 2)
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: nil, genre: nil)
        var new = original
        new.title = "fabric-mix"
        await #expect(throws: AlbumInfoError.keyTaken) {
            try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, tagEdit: env.tagEdit)
        }
        #expect(try await env.lib.albums.fetch(id: id)?.title == "Low Season")
        #expect(try await env.trackRow(tracks[0]).album == "Low Season")
        #expect(env.undo.stepCount == 0)
        #expect(AlbumInfoForm.keyTaken == "A base album with this title already exists. Use Merge with Another Album…")
        // The same title under another album artist is a different album.
        new.albumArtist = "Bicep"
        try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, tagEdit: env.tagEdit)
        #expect(try await env.lib.albums.fetch(id: id)?.albumArtist == "Bicep")
    }

    @Test func aCoverChosenInTheSheetIsPartOfTheSameStep() async throws {
        let env = try SheetEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MLM-sheet-covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: nil, genre: nil)
        var new = original
        new.title = "Low Season II"
        try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, cover: .data(png),
                                          coversDirectory: folder, tagEdit: env.tagEdit)
        #expect(try await env.lib.albums.fetch(id: id)?.coverPath != nil)
        #expect(env.undo.stepCount == 1)
        await env.undoStep()
        let back = try #require(try await env.lib.albums.fetch(id: id))
        #expect(back.coverPath == nil && back.title == "Low Season")
    }

    @Test func aFileThatIsNoImageWritesNothing() async throws {
        let env = try SheetEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        let original = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: nil, genre: nil)
        var new = original
        new.title = "Changed"
        await #expect(throws: AlbumCoverFiles.Failure.notAnImage) {
            try await env.edits.editAlbumInfo(albumID: id, original: original, new: new, trackIDs: tracks, cover: .data(Data("no".utf8)),
                                              coversDirectory: FileManager.default.temporaryDirectory, tagEdit: env.tagEdit)
        }
        #expect(try await env.lib.albums.fetch(id: id)?.title == "Low Season")
        #expect(env.undo.stepCount == 0)
    }

    @Test func nothingChangedIsNoStep() async throws {
        let env = try SheetEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        let values = AlbumInfoValues(title: "Low Season", albumArtist: "Overmono", year: nil, genre: nil)
        #expect(try await env.edits.editAlbumInfo(albumID: id, original: values, new: values, trackIDs: tracks, tagEdit: env.tagEdit) == nil)
        #expect(env.undo.stepCount == 0)
    }
}

// MARK: - Merge with Another Album

@Suite("AlbumMergeTests")
@MainActor
struct AlbumMergeTests {
    private func tracks(_ titles: [String]) -> [Track] {
        titles.enumerated().map { index, title in
            var track = Track(artist: "Overmono", album: "x", title: title, format: "flac", originalPath: "/x/\(title).flac")
            track.id = Int64(index + 1)
            return track
        }
    }

    @Test func thePlanCountsTracksThatMoveAndLookAlikes() {
        var other = tracks(["Clipper", "Gone", "Cinder"])
        for index in other.indices { other[index].id = Int64(100 + index) }
        let here = tracks(["clipper", "Cinder", "Other"])
        let plan = AlbumMergePlan.make(here: here, other: other)
        #expect(plan == AlbumMergePlan(moving: 3, duplicates: 2, firstDuplicateTitle: "clipper"), "the title as it is on this album")
        let sameTrack = AlbumMergePlan.make(here: here, other: [here[0]])
        #expect(sameTrack.moving == 0 && sameTrack.duplicates == 0, "a track already on the album doesn't move")
    }

    @Test func theConsequenceIsInNumbersAndMentionsDuplicatesOnlyWhenThereAreSome() {
        let some = AlbumMergePlan(moving: 3, duplicates: 1, firstDuplicateTitle: "Clipper")
        #expect(AlbumMergeText.consequence(plan: some, mode: .sameAlbum, this: "Low Season", other: "Low Season Bonus")
            == "3 tracks move to “Low Season”. 1 of them looks like a track that is already here (“Clipper”) and will be listed in Review ▸ Duplicates. “Low Season Bonus” is removed from Albums. Track order is not changed. You can undo the merge.")
        let none = AlbumMergePlan(moving: 1, duplicates: 0, firstDuplicateTitle: nil)
        #expect(AlbumMergeText.consequence(plan: none, mode: .sameAlbum, this: "Low Season", other: "Low Season Bonus")
            == "1 track moves to “Low Season”. “Low Season Bonus” is removed from Albums. Track order is not changed. You can undo the merge.")
        let many = AlbumMergePlan(moving: 12, duplicates: 4, firstDuplicateTitle: "Clipper")
        #expect(AlbumMergeText.consequence(plan: many, mode: .sameAlbum, this: "A", other: "B")
            .contains("4 of them look like tracks that are already here (“Clipper”) and will be listed in Review ▸ Duplicates."))
        #expect(AlbumMergeText.consequence(plan: some, mode: .edition(name: "Deluxe"), this: "Low Season", other: "Low Season (Deluxe)")
            == "“Low Season (Deluxe)” stays an album of its own and appears in the edition picker and under Other versions as “Deluxe”. You can undo this.")
    }

    @Test func theEditionNameStartsFromTheOtherTitleWhenItDiffers() {
        #expect(AlbumMergeText.editionNameDefault(this: "Low Season", other: "Low Season (Deluxe)") == "Low Season (Deluxe)")
        #expect(AlbumMergeText.editionNameDefault(this: "Low Season", other: "low-season") == "Deluxe")
        #expect(AlbumMergeText.editionNameDefault(this: "Low Season", other: nil) == "Deluxe")
    }

    /// Two albums of one artist, B with an edition and a preference, one track on both.
    private func fixture(_ lib: SheetLibrary) async throws -> (a: Int64, b: Int64, aTracks: [Int64], bTracks: [Int64], edition: Int64) {
        let (a, aTracks) = try await lib.album("Low Season", count: 3, numbers: [(1, 1), (1, 2), (2, 1)])
        let (b, bTracks) = try await lib.album("Low Season Bonus", count: 2, numbers: [(1, 1), (1, 2)])
        let edition: Int64 = try await lib.db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_of, variant_kind) VALUES ('Overmono', 'Overmono', 'low season deluxe', ?, ?, 'Deluxe')",
                           arguments: [AlbumKey.normalize("low season deluxe"), b])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO user_album_variant_pref (user_id, base_album_id, selected_album_id, updated_at) VALUES ('default', ?, ?, 'then')", arguments: [b, id])
            return id
        }
        return (a, b, aTracks, bTracks, edition)
    }

    @Test func sameAlbumAppendsTheOtherRowsKeepsDiscsAndRepointsEverything() async throws {
        let env = try SheetEnv()
        let f = try await fixture(env.lib)
        let shared = f.bTracks[0]
        try await env.lib.joins.add(trackIDs: [shared], to: f.a)   // on both albums: a primary-key collision
        try await env.edits.mergeAlbums(into: f.a, from: f.b, mode: .sameAlbum)

        let rows = try await env.lib.joins.rows(of: f.a)
        #expect(rows.map(\.trackId) == [f.aTracks[0], f.aTracks[1], f.bTracks[1], f.aTracks[2], shared],
                "disc 1: this album's two, then the other's second; disc 2: this album's rows (the shared track keeps its place)")
        #expect(rows.map(\.disc) == [1, 1, 1, 2, 2])
        #expect(rows.count == 5, "the shared track is listed once")
        #expect(try await env.lib.albums.fetch(id: f.b) == nil, "the other album is removed")
        #expect(try await env.lib.joins.rows(of: f.b).isEmpty)
        let linked = try await env.lib.db.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE album_id = ? ORDER BY id", arguments: [f.a]) }
        #expect(Set(linked) == Set(f.aTracks + f.bTracks), "tracks.album_id follows")
        let variant = try #require(try await env.lib.albums.fetch(id: f.edition))
        #expect(variant.variantOf == f.a, "the other's edition belongs to this album now")
        let pref = try await env.lib.db.read { db in
            try Row.fetchAll(db, sql: "SELECT base_album_id, selected_album_id FROM user_album_variant_pref").map { ($0["base_album_id"] as Int64, $0["selected_album_id"] as Int64) }
        }
        #expect(pref.count == 1 && pref[0].0 == f.a && pref[0].1 == f.edition)
        #expect(env.manager.undoMenuItemTitle == "Undo Merge Albums")
        #expect(env.status.message?.text == "Merged “Low Season Bonus” into “Low Season”")
        #expect(env.undo.stepCount == 1)
    }

    @Test func undoPutsTheExactRowsBackAndRedoMergesAgain() async throws {
        let env = try SheetEnv()
        let f = try await fixture(env.lib)
        try await env.lib.joins.add(trackIDs: [f.bTracks[0]], to: f.a)
        let beforeA = try await env.lib.joins.snapshot(albumID: f.a)
        let beforeB = try await env.lib.joins.snapshot(albumID: f.b)
        let rowB = try #require(try await env.lib.albums.fetch(id: f.b))
        try await env.edits.mergeAlbums(into: f.a, from: f.b, mode: .sameAlbum)
        let merged = try await env.lib.joins.snapshot(albumID: f.a)
        await env.undoStep()
        #expect(try await env.lib.joins.snapshot(albumID: f.a) == beforeA)
        #expect(try await env.lib.joins.snapshot(albumID: f.b) == beforeB)
        #expect(try await env.lib.albums.fetch(id: f.b) == rowB)
        #expect(try await env.lib.albums.fetch(id: f.edition)?.variantOf == f.b)
        let pref = try await env.lib.db.read { db in
            try Row.fetchAll(db, sql: "SELECT base_album_id, updated_at FROM user_album_variant_pref").map { ($0["base_album_id"] as Int64, $0["updated_at"] as String) }
        }
        #expect(pref.count == 1 && pref[0].0 == f.b && pref[0].1 == "then")
        await env.redoStep()
        #expect(try await env.lib.joins.snapshot(albumID: f.a) == merged)
        #expect(try await env.lib.albums.fetch(id: f.b) == nil)
    }

    @Test func anEditionStaysAnAlbumAndMovesNothing() async throws {
        let env = try SheetEnv()
        let f = try await fixture(env.lib)
        let beforeB = try await env.lib.joins.snapshot(albumID: f.b)
        let beforeA = try await env.lib.joins.snapshot(albumID: f.a)
        try await env.edits.mergeAlbums(into: f.a, from: f.b, mode: .edition(name: "Bonus"))
        let other = try #require(try await env.lib.albums.fetch(id: f.b))
        #expect(other.variantOf == f.a && other.variantKind == "Bonus")
        #expect(try await env.lib.joins.snapshot(albumID: f.b) == beforeB)
        #expect(try await env.lib.joins.snapshot(albumID: f.a) == beforeA)
        #expect(try await env.lib.albums.fetch(id: f.edition)?.variantOf == f.a)
        #expect(env.status.message?.text == "“Low Season Bonus” is now the edition “Bonus” of “Low Season”")
        await env.undoStep()
        let back = try #require(try await env.lib.albums.fetch(id: f.b))
        #expect(back.variantOf == nil && back.variantKind == nil)
        #expect(try await env.lib.albums.fetch(id: f.edition)?.variantOf == f.b)
        let pref = try await env.lib.db.read { db in try Int64.fetchAll(db, sql: "SELECT base_album_id FROM user_album_variant_pref") }
        #expect(pref == [f.b], "the preference of the group is back")
    }

    @Test func anEditionNameThatCollidesIsRefusedBeforeAnythingChanges() async throws {
        let env = try SheetEnv()
        let f = try await fixture(env.lib)
        try await env.lib.db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_of, variant_kind) VALUES ('Overmono', 'Overmono', 'Low Season Bonus', ?, ?, 'Bonus')",
                           arguments: [AlbumKey.normalize("Low Season Bonus"), f.a])
        }
        #expect(try await env.lib.albums.editionNameIsTaken("bonus", forAlbum: f.b))
        #expect(!(try await env.lib.albums.editionNameIsTaken("Deluxe", forAlbum: f.b)))
        await #expect(throws: AlbumMergeError.editionNameTaken) {
            try await env.edits.mergeAlbums(into: f.a, from: f.b, mode: .edition(name: "Bonus"))
        }
        #expect(try await env.lib.albums.fetch(id: f.b)?.variantOf == nil)
        #expect(env.undo.stepCount == 0)
    }

    @Test func theMergePlanReadsListedTracks() async throws {
        let env = try SheetEnv()
        let (a, _) = try await env.lib.album("Low Season", count: 3)
        let (b, bTracks) = try await env.lib.album("Low Season Too", count: 2)
        try await env.lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [bTracks[1]])
            try db.execute(sql: "UPDATE tracks SET title = 'Low Season 1' WHERE id = ?", arguments: [bTracks[0]])
        }
        let plan = try await env.lib.albums.mergePlan(into: a, from: b)
        #expect(plan == AlbumMergePlan(moving: 1, duplicates: 1, firstDuplicateTitle: "Low Season 1"), "hidden tracks are not counted")
    }

    @Test func mergingAnAlbumWithItselfOrAMissingOneThrows() async throws {
        let env = try SheetEnv()
        let (a, _) = try await env.lib.album("Low Season", count: 2)
        await #expect(throws: (any Error).self) { try await env.edits.mergeAlbums(into: a, from: a, mode: .sameAlbum) }
        await #expect(throws: (any Error).self) { try await env.edits.mergeAlbums(into: a, from: 9999, mode: .sameAlbum) }
        #expect(env.undo.stepCount == 0)
    }
}

// MARK: - Use a Track from the Library

@Suite("AlbumPlacementTests")
@MainActor
struct AlbumPlacementTests {
    @Test func aGapRowKnowsItsDiscAndNumber() {
        #expect(AlbumPlacement.position(ofPath: "album-absent://12/2/5")?.disc == 2)
        #expect(AlbumPlacement.position(ofPath: "album-absent://12/2/5")?.number == 5)
        #expect(AlbumPlacement.position(ofPath: "album-disc://12/2") == nil)
        #expect(AlbumPlacement.position(ofPath: "/Users/x/a.flac") == nil)
        let album = Album(id: 12, artist: "A", albumArtist: "A", title: "Low Season", titleNormalized: "lowseason", year: nil, coverPath: nil, variantOf: nil, variantKind: nil)
        let rows = AlbumLayout.rows(AlbumLayout(entries: [.absent(disc: 2, number: 5)], discCount: 1, expected: 5, absent: 1), members: [], album: album)
        #expect(rows.first.flatMap(AlbumPlacement.position(of:))?.number == 5, "the row the layout makes parses back")
    }

    @Test func theSentencesNameThePlace() {
        #expect(AlbumPlacement.sentence(album: "Low Season", disc: 1, number: 3, hasDiscs: false) == "The chosen track becomes track 3 of “Low Season”.")
        #expect(AlbumPlacement.sentence(album: "Low Season", disc: 2, number: 3, hasDiscs: true) == "The chosen track becomes track 3 on disc 2 of “Low Season”.")
        #expect(AlbumPlacement.footnote == "The track’s own tags are not changed.")
    }

    @Test func theLibraryListHasListedTracksNotOnTheAlbumAndFollowsTheSearch() async throws {
        let lib = try SheetLibrary()
        let (id, members) = try await lib.album("Low Season", count: 2)
        let (_, others) = try await lib.album("Fabric Mix", artist: "Bicep", count: 2)
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [others[1]]) }
        let all = try await lib.joins.libraryTracks(notOn: id, matching: .empty)
        #expect(Set(all.compactMap(\.id)) == [others[0]], "no member, no hidden track")
        #expect(!all.contains { members.contains($0.id ?? 0) })
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET search_text = LOWER(title || ' ' || artist)")
        }
        #expect(try await lib.joins.libraryTracks(notOn: id, matching: SearchFilter(text: "fabric")).count == 1)
        #expect(try await lib.joins.libraryTracks(notOn: id, matching: SearchFilter(text: "nothing like this")).isEmpty)
        #expect(try await lib.joins.libraryTracks(notOn: id, matching: .empty, limit: 0).isEmpty)
    }

    @Test func useTakesTheGapsDiscAndNumberRenumbersAndIsOneStepWithoutTagWrites() async throws {
        let env = try SheetEnv(writesEnabled: true)
        let (id, members) = try await env.lib.album("Low Season", count: 3, numbers: [(1, 1), (1, 3), (1, 4)])
        let (_, others) = try await env.lib.album("Fabric Mix", artist: "Bicep", count: 1)
        let chosen = others[0]
        let before = try await env.trackRow(chosen)
        try await env.edits.useTrack(chosen, inAlbum: id, disc: 1, number: 2)
        let rows = try await env.lib.joins.rows(of: id)
        #expect(rows.map(\.trackId) == [members[0], chosen, members[1], members[2]], "renumbered into its place")
        let placed = try #require(rows.first { $0.trackId == chosen })
        #expect(placed.disc == 1 && placed.trackNumber == 2)
        let after = try await env.trackRow(chosen)
        #expect(after.album == before.album && after.albumID == before.albumID, "its own album tag and link stay")
        #expect(try await env.pendingWrites().isEmpty, "no tag is written")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Low Season”")
        #expect(env.status.message?.text == "Added 1 track to “Low Season”")
        await env.undoStep()
        #expect(try await env.lib.joins.rows(of: id).map(\.trackId) == members)
        await env.redoStep()
        #expect(try await env.lib.joins.rows(of: id).map(\.trackId) == [members[0], chosen, members[1], members[2]])
    }

    @Test func useOnASecondDiscKeepsTheDisc() async throws {
        let env = try SheetEnv()
        let (id, members) = try await env.lib.album("Two Discs", count: 3, numbers: [(1, 1), (2, 1), (2, 3)])
        let (_, others) = try await env.lib.album("Elsewhere", artist: "Lone", count: 1)
        try await env.edits.useTrack(others[0], inAlbum: id, disc: 2, number: 2)
        let rows = try await env.lib.joins.rows(of: id)
        #expect(rows.map(\.trackId) == [members[0], members[1], others[0], members[2]])
        #expect(rows.map(\.disc) == [1, 2, 2, 2])
    }

    @Test func aTrackThatIsAlreadyOnTheAlbumIsNoStep() async throws {
        let env = try SheetEnv()
        let (id, members) = try await env.lib.album("Low Season", count: 2, numbers: [(1, 1), (1, 3)])
        let result = try await env.edits.useTrack(members[0], inAlbum: id, disc: 1, number: 2)
        #expect(result == nil)
        #expect(try await env.lib.joins.rows(of: id).compactMap(\.trackNumber) == [1, 3], "its number is untouched")
    }
}

// MARK: - Review ▸ Albums tab (IMP-103)

@Suite("ReviewAlbumsTabAlwaysShownTests")
@MainActor
struct ReviewAlbumsTabAlwaysShownTests {
    @Test func theAlbumsTabIsNeverHidden() {
        let items = ReviewModel.scopeItems(counts: { _ in 0 })
        #expect(ScopeBarRules.visibleItems(items, selection: .duplicates).map(\.id) == [.duplicates, .conflicts, .albums, .resolved])
        #expect(!items.contains { $0.hidesWhenEmpty })
    }
}
