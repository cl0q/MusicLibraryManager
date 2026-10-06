import Foundation
import Testing
@testable import MLM

/// The pure rules of the Genres place (W3-GEN): identity and display of a genre, the list's
/// fold of `GROUP BY genre` rows, spelling-variant hints, suggestion picking and the genre
/// menus' order.
@Suite("Genres: names, list, hints, suggestions, menus")
struct GenreModelTests {
    // MARK: Identity and display

    @Test func keyIgnoresCaseAndSurroundingSpaceAndBlankIsNoGenre() {
        #expect(GenreName.key("  House ") == "house")
        #expect(GenreName.key("house") == GenreName.key("HOUSE"))
        #expect(GenreName.key("Hip Hop") != GenreName.key("Hip-Hop"), "variants beyond case stay separate genres")
        #expect(GenreName.key(nil) == nil)
        #expect(GenreName.key("") == nil)
        #expect(GenreName.key(" \n\t") == nil)
    }

    @Test func displayPrefersTheMostFrequentWrittenCasingElseCapitalises() {
        // A casing a person wrote wins over the imported lower-case tag, even when rarer.
        #expect(GenreName.display(spellings: [("house", 900), ("House", 12)]) == "House")
        #expect(GenreName.display(spellings: [("House", 3), ("HOUSE", 9), ("house", 50)]) == "HOUSE")
        // Ties: alphabetical.
        #expect(GenreName.display(spellings: [("Uk Garage", 2), ("UK Garage", 2)]) == "UK Garage")
        // Only imported tags: words capitalised.
        #expect(GenreName.display(spellings: [("drum & bass", 4)]) == "Drum & Bass")
        #expect(GenreName.display(spellings: [("hip-hop", 4)]) == "Hip-Hop")
        #expect(GenreName.display(spellings: [("r&b", 1)]) == "R&B")
        #expect(GenreName.display(spellings: [("uk garage", 1)]) == "Uk Garage")
        #expect(GenreName.capitalized("drum'n'bass") == "Drum'n'bass")
    }

    @Test func cleanedNameTrimsAndCollapsesSpace() {
        #expect(GenreName.cleaned("  Deep   House ") == "Deep House")
        #expect(GenreName.cleaned("   ") == nil)
    }

    // MARK: The list

    @Test func overviewFoldsSpellingsByKeyAndCountsTracksWithoutGenre() {
        let overview = GenreOverview.fold(rows: [
            ("house", 10, 3_000), ("House", 2, 600), ("Techno", 7, 2_100), ("  ", 4, 0),
        ], totalTracks: 30)
        #expect(overview.genres.map(\.name) == ["House", "Techno"], "biggest first")
        let house = overview.genres[0]
        #expect(house.key == "house")
        #expect(house.trackCount == 12)
        #expect(house.duration == 3_600)
        #expect(house.spellings == ["House", "house"])
        #expect(overview.tracksWithGenre == 19)
        #expect(overview.tracksWithoutGenre == 11, "blank genres count as no genre")
    }

    @Test func factsLineNamesCountTimeAndBPMRange() {
        #expect(GenreText.facts(trackCount: 412, duration: 99_000, bpms: [0, 118, 134, 126]) == "412 tracks · 1 day · 118–134 BPM")
        #expect(GenreText.facts(trackCount: 1, duration: 300, bpms: [128]) == "1 track · 5 min · 128 BPM")
        #expect(GenreText.facts(trackCount: 2, duration: 600, bpms: []) == "2 tracks · 10 min")
        #expect(GenreText.subject(["Techno"]) == "“Techno”")
        #expect(GenreText.subject(["A", "B", "C"]) == "3 genres")
    }

    // MARK: Looks like … (V-GENRES.N03)

    private func genre(_ name: String, _ count: Int) -> GenreSummary {
        GenreSummary(key: GenreName.key(name)!, name: name, trackCount: count, duration: 0, spellings: [name])
    }

    @Test func lookalikesPointSmallerVariantsAtTheLargest() {
        let genres = [genre("Hip-Hop", 412), genre("Hip Hop", 37), genre("HipHop", 9), genre("Drum & Bass", 274),
                      genre("Drum and Bass", 12), genre("Tech House", 187), genre("tech-house", 2), genre("Techno", 1_612)]
        let hints = GenreLookalikes.hints(genres)
        #expect(hints["hip hop"]?.name == "Hip-Hop")
        #expect(hints["hiphop"]?.name == "Hip-Hop")
        #expect(hints["drum and bass"]?.name == "Drum & Bass")
        #expect(hints["tech-house"]?.name == "Tech House")
        #expect(hints["hip-hop"] == nil, "the largest gets no hint")
        #expect(hints["techno"] == nil)
        #expect(GenreLookalikes.group(of: genres[2], in: genres).map(\.name) == ["Hip-Hop", "Hip Hop", "HipHop"])
    }

    // MARK: Suggestions

    private func track(_ id: Int64, genre: String? = nil) -> Track {
        var track = Track(artist: "Artist", album: "", title: "Title \(id)", format: "m4a", originalPath: "/x/\(id).m4a")
        track.id = id
        track.genre = genre
        return track
    }

    @Test func pickLeavesOutTheGenreHiddenStagedTheReferenceAndTaggedTracksByDefault() {
        let candidates: [GenreSimilarityCandidate] = [
            .init(track: track(1), score: 0.97),
            .init(track: track(2, genre: "techno"), score: 0.96),  // already in the genre
            .init(track: track(3, genre: "House"), score: 0.95),   // has another genre
            .init(track: track(4), score: 0.93),                   // hidden
            .init(track: track(5), score: 0.91),                   // staged
            .init(track: track(6), score: 0.90),                   // the reference
            .init(track: track(7), score: 0.70),
            .init(track: track(8), score: 0.50),
        ]
        var options = GenreSuggestionOptions()
        let picked = GenreSuggestionRules.pick(candidates, genreKey: "techno", options: options,
                                               hidden: [4], staged: [5], reference: 6)
        #expect(picked.map(\.id) == [1, 7], "Balanced drops matches under 68 %")
        #expect(picked.first?.matchPercent == 97)

        options.onlyTracksWithoutGenre = false
        options.match = .wide
        let wide = GenreSuggestionRules.pick(candidates, genreKey: "techno", options: options,
                                             hidden: [4], staged: [5], reference: 6)
        #expect(wide.map(\.id) == [1, 3, 7, 8], "never the genre's own tracks")

        options.match = .close
        options.count = 10
        #expect(GenreSuggestionRules.pick(candidates, genreKey: "techno", options: options, hidden: [], staged: [],
                                          reference: nil).map(\.id) == [1, 3, 4, 5, 6])
    }

    @Test func pickStopsAtTheCount() {
        let candidates = (1...30).map { GenreSimilarityCandidate(track: track(Int64($0)), score: 0.99 - Float($0) / 1_000) }
        var options = GenreSuggestionOptions()
        #expect(GenreSuggestionRules.pick(candidates, genreKey: "x", options: options, hidden: [], staged: [], reference: nil).count == 10)
        options.count = 20
        #expect(GenreSuggestionRules.pick(candidates, genreKey: "x", options: options, hidden: [], staged: [], reference: nil).count == 20)
        #expect(GenreSuggestionRules.requestLimit(options) >= 20)
    }

    @Test func optionsAreRememberedAndWordedWithoutJargon() throws {
        let defaults = try #require(UserDefaults(suiteName: "GenreModelTests.\(UUID().uuidString)"))
        #expect(GenreSuggestionOptions.load(defaults) == GenreSuggestionOptions(), "defaults: Balanced, 10, only without a genre")
        #expect(GenreSuggestionOptions().onlyTracksWithoutGenre)
        let options = GenreSuggestionOptions(match: .close, count: 20, onlyTracksWithoutGenre: false)
        options.save(defaults)
        #expect(GenreSuggestionOptions.load(defaults) == options)
        #expect(GenreSuggestionOptions.Match.allCases.map(\.title) == ["Close", "Balanced", "Wide"], "UC-COPY-15: no Temperature")
    }

    // MARK: Menus (CM-GENRE-ROW, CM-GENRED-MORE, UC-CM-02/04)

    @Test func rowMenuForOneGenre() {
        #expect(GenreMenuModel.sections(.row, count: 1) == [[.open, .play], [.playNext, .addToQueue],
                                                            [.addToPlaylist, .addToSyncProfile], [.rename]])
    }

    @Test func rowMenuForSeveralGenresHasACountAndMergeButNoOpenOrRename() {
        let sections = GenreMenuModel.sections(.row, count: 3)
        #expect(sections.first == [.countHeader(3)])
        #expect(GenreMenuModel.title(.countHeader(3)) == "3 genres")
        #expect(!sections.joined().contains(.open))
        #expect(!sections.joined().contains(.rename))
        #expect(sections.last == [.merge])
    }

    @Test func moreMenuLeavesPlayAndShuffleToTheHeader() {
        let items = GenreMenuModel.sections(.more, count: 1).joined()
        #expect(Array(items) == [.playNext, .addToQueue, .addToPlaylist, .addToSyncProfile, .rename, .mergeWithAnother])
        #expect(items.map(GenreMenuModel.title) == ["Play Next", "Add to Queue", "Add to Playlist", "Add to Sync Profile",
                                                    "Rename Genre…", "Merge with Another Genre…"])
    }
}
