import Foundation
import Testing
@testable import MLM

/// The Albums surfaces' words and rules (W4-2): card lines, status bar, facts, the status line,
/// the in-place filter, the page's layout (gaps, discs), Edit Order's moves, the menus, type-select.
@Suite("AlbumPresentationTests")
struct AlbumPresentationTests {
    // MARK: Fixtures

    static func album(_ id: Int64 = 1, title: String = "Low Season", artist: String = "Overmono", year: Int? = 2019,
                      kind: String? = nil) -> Album {
        Album(id: id, artist: artist, albumArtist: artist, title: title, titleNormalized: AlbumKey.normalize(title),
              year: year, coverPath: nil, variantOf: nil, variantKind: kind)
    }

    static func track(_ id: Int64, title: String? = nil, artist: String = "Overmono", duration: Int? = 200) -> Track {
        var track = Track(artist: artist, album: "Low Season", title: title ?? "T\(id)", format: "flac", originalPath: "/tmp/\(id).flac")
        track.id = id
        track.duration = duration
        track.organizedPath = "Overmono/Low Season/\(id).flac"
        return track
    }

    static func member(_ id: Int64, disc: Int = 1, number: Int?, duration: Int? = 200) -> AlbumMember {
        AlbumMember(track: track(id, duration: duration), disc: disc, number: number)
    }

    static func listing(_ album: Album = album(), tracks: Int = 12, artists: Int = 1,
                        numbers: [(Int, Int?)]? = nil) -> AlbumListing {
        AlbumListing(album: album, trackCount: tracks, artistCount: artists, lastAdded: nil,
                     tracklist: AlbumTracklist(numbers ?? []))
    }

    /// Counts use the user's thousands separator (UC-COPY-09).
    static func big(_ number: Int) -> String { number.formatted(.number) }

    // MARK: Words

    @Test func theCardLineSaysYearAndTracksOrIncompleteInWords() {
        #expect(AlbumText.cardLine(Self.listing()) == "2019 · 12 tracks")
        #expect(AlbumText.cardLine(Self.listing(Self.album(year: nil), tracks: 1)) == "1 track")
        let incomplete = Self.listing(tracks: 3, numbers: [(1, 1), (1, 2), (1, 5)])
        #expect(incomplete.isIncomplete)
        #expect(AlbumText.cardLine(incomplete) == "2019 · Incomplete · 3 of 5")
        let filled = Self.listing(tracks: 3, numbers: [(1, 1), (1, 2), (1, 3)])
        #expect(AlbumText.cardLine(filled) == "2019 · 3 tracks")
    }

    @Test func theStatusBarCountsAlbumsAndSaysShownOfTotalWhileFiltered() {
        #expect(AlbumText.statusText(shown: 1204, total: 1204, isFiltered: false) == "\(Self.big(1204)) albums")
        #expect(AlbumText.statusText(shown: 12, total: 1204, isFiltered: true) == "12 of \(Self.big(1204)) albums")
        #expect(AlbumText.statusText(shown: 1, total: 1, isFiltered: false) == "1 album")
        #expect(AlbumText.statusText(shown: 3, total: 3, isFiltered: true) == "3 albums", "nothing hidden: no `of`")
        let one = Self.listing()
        #expect(AlbumText.selectedText([one]) == "“Low Season” selected · 12 tracks")
        #expect(AlbumText.selectedText([one, Self.listing(Self.album(2, title: "B"), tracks: 3)]) == "2 albums selected · 15 tracks")
        #expect(AlbumText.selectedText([]) == nil)
    }

    @Test func theFooterAndTheEmptyStateSayHowManyTracksHaveNoAlbum() {
        #expect(AlbumText.noAlbumLine(6341) == "\(Self.big(6341)) tracks have no album")
        #expect(AlbumText.noAlbumLine(1) == "1 track has no album")
        #expect(AlbumText.emptyDescription(noAlbumCount: 6341)
            == "Albums appear when tracks carry album information. \(Self.big(6341)) tracks in this library have no album.")
        #expect(AlbumText.emptyDescription(noAlbumCount: 0) == "Albums appear when tracks carry album information.")
    }

    @Test func theFactsLineCountsTheTracklistAndShowsWhatIsKnown() {
        #expect(AlbumText.facts(year: 2019, genre: "Techno", trackCount: 12, duration: 58 * 60) == "2019 · Techno · 12 tracks · 58 min")
        #expect(AlbumText.facts(year: nil, genre: nil, trackCount: 1, duration: 0) == "1 track")
        #expect(AlbumText.discHeading(disc: 2, tracks: 12, duration: 58 * 60) == "Disc 2 · 12 tracks · 58 min")
        #expect(AlbumText.kindLabel(isCompilation: true) == "Compilation")
        #expect(AlbumText.kindLabel(isCompilation: false) == "Album")
        #expect(AlbumText.playPaused(volume: "Lexxar") == "Play and Shuffle are paused — “Lexxar” is not connected.")
    }

    @Test func editionsAreNamedAndSaidInNumbers() {
        #expect(AlbumText.editionName(Self.album()) == "Standard edition")
        #expect(AlbumText.editionName(Self.album(kind: "deluxe")) == "Deluxe edition")
        #expect(AlbumText.editionName(Self.album(kind: "2021 Remaster")) == "2021 Remaster")
        #expect(AlbumText.editionLine(name: "Deluxe edition", year: 2020, inLibrary: 12, total: 16)
            == "Deluxe edition (2020) — 12 of 16 in library")
        #expect(AlbumText.editionLine(name: "Standard edition", year: nil, inLibrary: 1, total: 1) == "Standard edition — 1 of 1 in library")
        #expect(AlbumText.shelfLine(year: 2021, inLibrary: 3, total: 12) == "2021 · 3 of 12 in library")
    }

    @Test func theStatusLineSaysWhatIsMissingAndOffersTheBatch() {
        #expect(AlbumStatusLine.make(absent: 0, expected: 12, failed: 0, notDownloaded: 0) == nil, "a complete album says nothing")
        let line = AlbumStatusLine.make(absent: 2, expected: 12, failed: 0, notDownloaded: 0)
        #expect(line?.text == "Incomplete · 2 of 12 not in library")
        #expect(line?.downloadCount == 0, "nothing to fetch: no button")
        let mixed = AlbumStatusLine.make(absent: 2, expected: 12, failed: 1, notDownloaded: 3)
        #expect(mixed?.text == "Incomplete · 2 of 12 not in library · 1 download failed · 3 not downloaded")
        #expect(mixed?.downloadCount == 4)
        #expect(mixed?.downloadTitle == "Download 4 Missing")
        #expect(AlbumStatusLine.make(absent: 0, expected: nil, failed: 2, notDownloaded: 0)?.text == "Incomplete · 2 failed")
        #expect(AlbumStatusLine.make(absent: 0, expected: nil, failed: 0, notDownloaded: 1)?.text == "Not downloaded · 1 track")
    }

    @Test func removingAnAlbumStatesTheConsequenceInNumbers() {
        let one = AlbumRemoval.confirmation(titles: ["Low Season"], trackCount: 10, fileCount: 10, playlists: 3, syncProfiles: 1)
        #expect(one.title == "Remove “Low Season” from the library?")
        #expect(one.message == "Its 10 tracks are removed from the library, from 3 playlists and 1 sync profile, and their files move to the Trash. You can put the files back from the Trash.")
        #expect(one.confirmTitle == "Move to Trash")
        let none = AlbumRemoval.confirmation(titles: ["Low Season"], trackCount: 10, fileCount: 0, playlists: 0, syncProfiles: 0)
        #expect(none.message == "Its 10 tracks are removed from the library. Nothing moves to the Trash — they have no files.")
        #expect(none.confirmTitle == "Remove from Library")
        let several = AlbumRemoval.confirmation(titles: ["A", "B"], trackCount: 5, fileCount: 3, playlists: 1, syncProfiles: 0)
        #expect(several.title == "Remove 2 albums from the library?")
        #expect(several.message.contains("the files of 3 tracks move to the Trash"))
    }

    // MARK: The in-place filter

    @Test func theFilterAppliesFreeWordsAndTheThreeTokens() throws {
        let listing = Self.listing()
        let other = Self.listing(Self.album(2, title: "Good Lies", artist: "Overmono", year: 2023))
        let various = Self.listing(Self.album(3, title: "fabric", artist: "Various Artists", year: 2021))
        func shown(_ filter: SearchFilter) -> [Int64] { [listing, other, various].filter { AlbumFilterRules.matches($0, filter) }.map(\.id) }
        #expect(shown(.empty) == [1, 2, 3])
        #expect(shown(SearchFilter(text: "season")) == [1])
        #expect(shown(SearchFilter(text: "overmono 2023")) == [2], "title, artist and year are one text")
        #expect(shown(SearchFilter(tokens: [.artist("Overmono")])) == [1, 2])
        #expect(shown(SearchFilter(tokens: [.album("Good Lies")])) == [2])
        #expect(shown(SearchFilter(tokens: [.year(SearchNumberRange(2019, 2021))])) == [1, 3])
        #expect(shown(SearchFilter(tokens: [.artist("various", exact: false), .album("fabric")])) == [3], "kinds combine with AND")
        #expect(shown(SearchFilter(tokens: [.genre("Techno")])) == [1, 2, 3], "tokens the grid can't apply filter nothing")
    }

    @MainActor @Test func albumsAreAPlaceThatTakesThreeKindsOfTokens() throws {
        let filter = SearchFilter(text: "low", tokens: [.artist("Overmono"), .genre("Techno"), .availability(.noAlbum)])
        let applied = filter.applicable(to: .albums)
        #expect(applied.tokens.map(\.kind) == [.artist])
        #expect(filter.ignoredTokens(for: .albums).map(\.kind) == [.genre, .availability])
        let place = SearchPlace(key: .albums, capability: .albums, name: "Albums")
        #expect(place.offeredKinds == [.artist, .album, .year])
        let navigation = NavigationModel(selection: .albums)
        #expect(SearchPlace(navigation).capability == .albums)
        navigation.push(.album(7))
        #expect(SearchPlace(navigation).capability == .tracks, "an album's page filters its tracks")
        #expect(SearchPlace(navigation).key == .album(7))
    }

    // MARK: The page's layout

    @Test func aKnownTracklistShowsAGapRowWhereANumberIsMissing() {
        let members = [Self.member(10, number: 1), Self.member(11, number: 2), Self.member(12, number: 5)]
        let layout = AlbumLayout.make(members: members)
        #expect(layout.entries == [.track(10), .track(11), .absent(disc: 1, number: 3), .absent(disc: 1, number: 4), .track(12)])
        #expect(layout.absent == 2)
        #expect(layout.expected == 5)
        #expect(layout.discCount == 1)
    }

    @Test func withoutNumbersThereIsNoTracklistAndNoGap() {
        let members = [Self.member(10, number: nil), Self.member(11, number: 2)]
        let layout = AlbumLayout.make(members: members)
        #expect(layout.entries == [.track(10), .track(11)])
        #expect(layout.absent == 0)
        #expect(layout.expected == nil)
    }

    @Test func eachDiscGetsAHeadingAndItsOwnGaps() {
        let members = [Self.member(1, disc: 1, number: 1), Self.member(2, disc: 1, number: 3),
                       Self.member(3, disc: 2, number: 1), Self.member(4, disc: 2, number: 2)]
        let layout = AlbumLayout.make(members: members)
        #expect(layout.entries == [
            .header(disc: 1, tracks: 3, duration: 400), .track(1), .absent(disc: 1, number: 2), .track(2),
            .header(disc: 2, tracks: 2, duration: 400), .track(3), .track(4),
        ])
        #expect(layout.discCount == 2)
        #expect(layout.expected == 5, "3 on disc 1 and 2 on disc 2")
        #expect(layout.absent == 1)
    }

    @Test func gapsAndHeadingsBecomeSyntheticRowsWithTheirOwnWords() throws {
        let members = [Self.member(1, disc: 1, number: 1), Self.member(2, disc: 1, number: 3),
                       Self.member(3, disc: 2, number: 1)]
        let layout = AlbumLayout.make(members: members)
        let rows = AlbumLayout.rows(layout, members: members, album: Self.album())
        #expect(rows.map(\.synthetic) == [.discHeader, .none, .absent, .none, .discHeader, .none])
        #expect(rows.map(\.position) == [1, 2, 3, 4, 5, 6], "one fixed order across discs")
        #expect(rows.map(\.displayNumber) == [nil, 1, 2, 3, nil, 1], "the number within the disc")
        let gap = try #require(rows.first { $0.synthetic == .absent })
        #expect(gap.title == "Track 2")
        #expect(gap.id < 0 && rows.filter { !$0.isTrack }.allSatisfy { $0.id < 0 })
        #expect(Set(rows.map(\.id)).count == rows.count, "synthetic ids never meet each other or a track")
        let presentation = TrackRowPresentation(row: gap, live: .idle)
        #expect(presentation.status == .notInLibrary)
        #expect(presentation.isDimmed)
        #expect(!presentation.isNowPlaying)
        let header = try #require(rows.first { $0.synthetic == .discHeader })
        #expect(header.title == "Disc 1 · 3 tracks · 7 min")
        #expect(TrackRowPresentation(row: header, live: .idle).status == nil)
    }

    @Test func aNumberFromTheFileIsShownElseTheIndexWithinTheDisc() {
        let members = [Self.member(1, number: nil), Self.member(2, number: nil)]
        let rows = AlbumLayout.rows(AlbumLayout.make(members: members), members: members, album: Self.album())
        #expect(rows.map(\.displayNumber) == [1, 2])
        let numbered = [Self.member(1, number: 4), Self.member(2, number: 7)]
        let shown = AlbumLayout.rows(AlbumLayout.make(members: numbered), members: numbered, album: Self.album())
        #expect(shown.compactMap { $0.isTrack ? $0.displayNumber : nil } == [4, 7])
        let renumbered = AlbumLayout.rows(AlbumLayout.make(members: numbered, fillsGaps: false), members: numbered, album: Self.album(), renumber: true)
        #expect(renumbered.map(\.displayNumber) == [1, 2], "Edit Order shows 1, 2, 3…")
    }

    // MARK: Edit Order

    private func editor(_ spec: [(Int64, Int)]) -> AlbumOrderEditor {
        AlbumOrderEditor(items: spec.map { AlbumOrderEditor.Item(trackID: $0.0, disc: $0.1) })
    }

    private func order(_ editor: AlbumOrderEditor) -> [[Int64]] {
        editor.discs.map { disc in editor.items.filter { $0.disc == disc }.map(\.trackID) }
    }

    @Test func dragARowBeforeAnotherAndTheNumbersFollow() {
        var editor = editor([(1, 1), (2, 1), (3, 1)])
        #expect(editor.rows == [.track(1), .track(2), .track(3)], "a single disc has no heading")
        do { let result = editor.move([3], toRow: 0); #expect(result) }
        #expect(order(editor) == [[3, 1, 2]])
        #expect(editor.numbered.map(\.number) == [1, 2, 3])
        #expect(editor.numbered.map(\.trackID) == [3, 1, 2])
        do { let result = editor.move([3], toRow: 0); #expect(!result, "dropped where it is: nothing changes") }
        do { let result = editor.move([3], toRow: 3); #expect(result) }
        #expect(order(editor) == [[1, 2, 3]])
    }

    @Test func aRowDroppedUnderAnotherDiscsHeadingJoinsThatDisc() {
        var editor = editor([(1, 1), (2, 1), (3, 2), (4, 2)])
        #expect(editor.rows == [.header(disc: 1), .track(1), .track(2), .header(disc: 2), .track(3), .track(4)])
        // Display row 4 is the first row of disc 2: the line above is the heading of disc 2.
        do { let result = editor.move([1], toRow: 4); #expect(result) }
        #expect(order(editor) == [[2], [1, 3, 4]])
        #expect(editor.numbered.map { "\($0.disc).\($0.number)" } == ["1.1", "2.1", "2.2", "2.3"])
        // Dropped before the heading of disc 2: it stays at the end of disc 1.
        var other = self.editor([(1, 1), (2, 1), (3, 2)])
        do { let result = other.move([3], toRow: 3); #expect(result) }
        #expect(order(other) == [[1, 2, 3]], "a lone disc has no heading; the album is one disc now")
    }

    @Test func optionArrowsMoveTheSelectedRowsOneRowAcrossDiscs() {
        var editor = editor([(1, 1), (2, 1), (3, 2)])
        do { let result = editor.nudge([2], by: -1); #expect(result) }
        #expect(order(editor) == [[2, 1], [3]])
        do { let result = editor.nudge([2], by: -1); #expect(!result, "the first row can't go up") }
        do { let result = editor.nudge([1], by: 1); #expect(result, "the last row of disc 1 goes down into disc 2") }
        #expect(order(editor) == [[2], [1, 3]])
        do { let result = editor.nudge([1], by: 1); #expect(result) }
        #expect(order(editor) == [[2], [3, 1]])
        do { let result = editor.nudge([1], by: 1); #expect(!result, "the last row can't go down") }
        do { let result = editor.nudge([], by: 1); #expect(!result) }
    }

    @Test func severalRowsMoveTogetherInTheirOrder() {
        var editor = editor([(1, 1), (2, 1), (3, 1), (4, 1)])
        do { let result = editor.move([4, 2], toRow: 0); #expect(result) }
        #expect(order(editor) == [[4, 2, 1, 3]])
    }

    // MARK: The menus

    @Test func theCardMenuIsTheCatalogueInItsOrder() {
        let sections = AlbumMenuModel.sections(.card, facts: .init(artist: "Overmono", missing: 2))
        #expect(sections == [
            [.play], [.playNext, .addToQueue], [.addToPlaylist, .addToSyncProfile], [.getInfo, .goToArtist("Overmono")],
            [.download(2)], [.showInFinder], [.removeFromLibrary],
        ])
        #expect(AlbumMenuModel.title(.download(2)) == "Download 2 Missing")
        let complete = AlbumMenuModel.sections(.card, facts: .init(artist: "Overmono", missing: 0))
        #expect(!complete.flatMap { $0 }.contains { if case .download = $0 { true } else { false } }, "no Download line for a downloaded album")
        let compilation = AlbumMenuModel.sections(.card, facts: .init(artist: nil))
        #expect(compilation[3] == [.getInfo], "no Go to Artist for a compilation")
        let several = AlbumMenuModel.sections(.card, facts: .init(isMultiple: true, artist: "Overmono"))
        #expect(several.count == 5 && !several.flatMap { $0 }.contains(.getInfo), "Get Info and Go to are for one album")
    }

    @Test func theMoreMenuStartsWithTheQueueAndKeepsTheLaterPackagesInPlace() {
        let sections = AlbumMenuModel.sections(.more, facts: .init(artist: "Overmono", missing: 1))
        #expect(sections == [
            [.playNext, .addToQueue], [.addToPlaylist, .addToSyncProfile],
            [.editAlbumInfo, .chooseCover, .editOrder, .mergeWithAnother], [.download(1)], [.showInFinder], [.removeFromLibrary],
        ])
        #expect(AlbumMenuModel.title(.editAlbumInfo) == "Edit Album Info…")
        #expect(AlbumMenuModel.title(.mergeWithAnother) == "Merge with Another Album…")
        #expect(AlbumMenuModel.title(.removeFromLibrary) == "Remove from Library…")
    }

    @Test func aCompilationsArtistIsPlainText() {
        #expect(AlbumMenuModel.artistLink(albumArtist: "Overmono", isCompilation: false) == "Overmono")
        #expect(AlbumMenuModel.artistLink(albumArtist: "Various Artists", isCompilation: false) == nil)
        #expect(AlbumMenuModel.artistLink(albumArtist: "Overmono", isCompilation: true) == nil)
        #expect(AlbumMenuModel.artistLink(albumArtist: "  ", isCompilation: false) == nil)
    }

    // MARK: Type to select

    @Test func typingATitleSelectsTheFirstAlbumThatStartsWithIt() {
        let titles: [(id: Int64, title: String)] = [(1, "Amygdala"), (2, "Arpo"), (3, "Burial"), (4, "Élan")]
        #expect(AlbumTypeSelect.match("ar", in: titles, after: nil) == 2)
        #expect(AlbumTypeSelect.match("a", in: titles, after: nil) == 1)
        #expect(AlbumTypeSelect.match("a", in: titles, after: 1) == 2, "from the current one on")
        #expect(AlbumTypeSelect.match("aa", in: titles, after: 1) == 2, "the same letter again steps on")
        #expect(AlbumTypeSelect.match("el", in: titles, after: nil) == 4, "diacritics are ignored")
        #expect(AlbumTypeSelect.match("zz", in: titles, after: nil) == nil)
        #expect(AlbumTypeSelect.match("", in: titles, after: nil) == nil)
    }

    @Test func aPauseStartsANewPrefix() {
        var select = AlbumTypeSelect()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(select.type("a", at: start) == "a")
        #expect(select.type("r", at: start.addingTimeInterval(0.4)) == "ar")
        #expect(select.type("b", at: start.addingTimeInterval(2)) == "b")
    }

    // MARK: Track menu: Go to Album

    @MainActor @Test func goToAlbumIsInTheInfoGroupAfterGetInfoForOneTrackWithAnAlbum() {
        var track = Self.track(1)
        track.albumId = 5
        let row = TrackRowBuilder.build([track])[0]
        let context = TrackMenuContext(container: .library, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
        let menu = TrackMenuModel.make(subject: TrackMenuSubject(rows: [row], live: .idle), context: context)
        let info = menu.sections.first { $0.contains(.getInfo) } ?? []
        #expect(info.prefix(3) == [.getInfo, .goToAlbum(5), .goToArtist("Overmono")])
        // No album: no item. Inside that album: no item. Several tracks: no item.
        let plain = TrackRowBuilder.build([Self.track(2)])[0]
        #expect(!TrackMenuModel.make(subject: TrackMenuSubject(rows: [plain], live: .idle), context: context).items.contains { if case .goToAlbum = $0 { true } else { false } })
        var inAlbum = context
        inAlbum.container = .album(id: 5, name: "Low Season")
        inAlbum.canRemoveFromContainer = true
        #expect(!TrackMenuModel.make(subject: TrackMenuSubject(rows: [row], live: .idle), context: inAlbum).items.contains { if case .goToAlbum = $0 { true } else { false } })
        #expect(TrackMenuModel.make(subject: TrackMenuSubject(rows: [row], live: .idle), context: inAlbum).items.contains(.removeFromContainer(title: "Remove from “Low Season”")))
        #expect(!TrackMenuModel.make(subject: TrackMenuSubject(rows: [row, plain], live: .idle), context: context).items.contains { if case .goToAlbum = $0 { true } else { false } })
    }

    @MainActor @Test func theCatalogHasGoToAlbumWired() {
        #expect(!MenuCommand.goToAlbum.isPending)
        #expect(MenuCommand.goToAlbum.title == "Go to Album")
    }
}
