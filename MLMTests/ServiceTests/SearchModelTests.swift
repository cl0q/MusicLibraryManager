import Foundation
import Testing
@testable import MLM

/// The pure search model (W2-I, UC-SEARCH-04): token grammar, the filter, links, recents.
@Suite("Search query parser")
struct SearchQueryParserTests {
    @Test func plainWordsAreFreeText() {
        let parsed = SearchQueryParser.parse("  skee   mask ")
        #expect(parsed.freeText == "skee mask")
        #expect(parsed.tokens.isEmpty)
        #expect(parsed.trailing == nil)
    }

    @Test func textKindsRunToTheNextFilterWordOrTheEnd() {
        let parsed = SearchQueryParser.parse("remix artist: Skee Mask genre:techno")
        #expect(parsed.freeText == "remix")
        #expect(parsed.tokens == [.artist("Skee Mask", exact: false), .genre("techno", exact: false)])
        #expect(parsed.trailing == SearchTrailingClause(kind: .genre, partialValue: "techno", textBefore: "remix artist: Skee Mask"))
    }

    @Test func quotedValuesAreExactAndLeaveTheRestFree() {
        let parsed = SearchQueryParser.parse("genre:\"Tech House\" warm")
        #expect(parsed.tokens == [.genre("Tech House")])
        #expect(parsed.freeText == "warm")
        let curly = SearchQueryParser.parse("album: “Compro”")
        #expect(curly.tokens == [.album("Compro")])
    }

    @Test func anOpenQuoteIsStillBeingTyped() {
        let parsed = SearchQueryParser.parse("artist:\"Skee")
        #expect(parsed.trailing?.kind == .artist)
        #expect(parsed.trailing?.partialValue == "Skee")
    }

    @Test(arguments: [
        ("bpm: 120–128", SearchNumberRange(120, 128)),
        ("bpm: 120-128", SearchNumberRange(120, 128)),
        ("bpm:120 - 128", SearchNumberRange(120, 128)),
        ("bpm: 128..120", SearchNumberRange(120, 128)),
        ("bpm: 128", SearchNumberRange(128, 128)),
    ])
    func bpmRanges(text: String, range: SearchNumberRange) {
        #expect(SearchQueryParser.parse(text).tokens == [.bpm(range)])
    }

    @Test func yearTakesOneRangeAndTheRestIsFree() {
        let parsed = SearchQueryParser.parse("year: 2015–2019 live")
        #expect(parsed.tokens == [.year(SearchNumberRange(2015, 2019))])
        #expect(parsed.freeText == "live")
        #expect(SearchNumberRange(2015, 2019).text == "2015–2019")
    }

    @Test func availabilityWordsTakeTheLongestPhrase() {
        let parsed = SearchQueryParser.parse("is: not downloaded overmono")
        #expect(parsed.tokens == [.availability(.notDownloaded)])
        #expect(parsed.freeText == "overmono")
        #expect(SearchQueryParser.parse("is:no album").tokens == [.availability(.noAlbum)])
        #expect(SearchQueryParser.parse("is: not analyzed").tokens == [.availability(.notAnalysed)])
        #expect(SearchQueryParser.parse("is: linked to soundcloud").tokens == [.availability(.linkedToSoundCloud)])
    }

    @Test func aPartWordIsPendingNotApplied() {
        let parsed = SearchQueryParser.parse("is: not dow")
        #expect(parsed.tokens.isEmpty)
        #expect(parsed.trailing == SearchTrailingClause(kind: .availability, partialValue: "not dow", textBefore: ""))
        #expect(parsed.unresolved.isEmpty)
    }

    @Test func valuesThatArentUnderstoodAreNotApplied() {
        let parsed = SearchQueryParser.parse("bpm: fast genre: techno")
        #expect(parsed.tokens == [.genre("techno", exact: false)])
        #expect(parsed.unresolved == ["bpm: fast"])
        let word = SearchQueryParser.parse("is: shiny artist: x")
        #expect(word.unresolved == ["is: shiny"])
    }

    @Test func unknownKeysAndLinksStayText() {
        #expect(SearchQueryParser.parse("Re:Edit mood:dark").freeText == "Re:Edit mood:dark")
        #expect(SearchQueryParser.parse("Re:Edit").tokens.isEmpty)
        #expect(SearchQueryParser.parse("myartist:x").tokens.isEmpty, "Only at the start of a word")
    }

    @Test func keysIgnoreCase() {
        #expect(SearchQueryParser.parse("GENRE:Techno").tokens == [.genre("Techno", exact: false)])
    }

    @Test func anEmptyValueIsTheClauseBeingTyped() {
        let parsed = SearchQueryParser.parse("warm genre:")
        #expect(parsed.tokens.isEmpty)
        #expect(parsed.trailing == SearchTrailingClause(kind: .genre, partialValue: "", textBefore: "warm"))
        #expect(parsed.freeText == "warm")
    }

    @Test func tokensShowLikeTheDesign() {
        #expect(SearchToken.genre("Techno").displayText == "genre: Techno")
        #expect(SearchToken.availability(.notDownloaded).displayText == "is: not downloaded")
        #expect(SearchToken.bpm(SearchNumberRange(120, 128)).displayText == "bpm: 120–128")
        #expect(SearchToken.genre("Techno").id == SearchToken.genre("techno").id, "One identity ignoring case")
        #expect(SearchToken.genre("Techno").id != SearchToken.genre("Techno", exact: false).id)
    }
}

@Suite("Search filter in memory")
struct SearchFilterMatchingTests {
    private func track(
        artist: String = "Overmono", album: String = "Good Lies", title: String = "So U Kno",
        genre: String? = "Techno", year: Int? = 2023, bpm: Int? = 130, path: String? = "A/1.m4a",
        energy: Int? = 3, original: String = "/x.m4a"
    ) -> Track {
        var track = Track(artist: artist, album: album, title: title, format: "m4a", originalPath: original)
        track.genre = genre
        track.year = year
        track.bpm = bpm
        track.organizedPath = path
        track.energyBucket = energy
        return track
    }

    @Test func freeWordsAreAndedAndFolded() {
        #expect(SearchFilter(text: "overmono kno").matches(track()))
        #expect(!SearchFilter(text: "overmono skee").matches(track()))
        #expect(SearchFilter(text: "björk").matches(track(artist: "Bjork")))
    }

    @Test func kindsAreAndedValuesOfOneKindOred() {
        let either = SearchFilter(tokens: [.genre("House"), .genre("Techno")])
        #expect(either.matches(track()))
        let both = SearchFilter(tokens: [.genre("Techno"), .year(SearchNumberRange(2010, 2015))])
        #expect(!both.matches(track()))
    }

    @Test func chosenValuesAreExactTypedOnesContain() {
        #expect(!SearchFilter(tokens: [.genre("Tech")]).matches(track()))
        #expect(SearchFilter(text: "genre:tech").matches(track()))
        #expect(SearchFilter(tokens: [.artist("overmono")]).matches(track()), "Exact ignores case")
        #expect(SearchFilter(tokens: [.artist("Various")]).matches(track(artist: "X")) == false)
    }

    @Test func availabilityAndFacts() {
        #expect(SearchFilter(tokens: [.availability(.local)]).matches(track()))
        #expect(SearchFilter(tokens: [.availability(.notDownloaded)]).matches(track(path: nil)))
        #expect(SearchFilter(tokens: [.availability(.noAlbum)]).matches(track(album: "YouTube")))
        #expect(SearchFilter(tokens: [.availability(.noAlbum)]).matches(track(album: "")))
        #expect(!SearchFilter(tokens: [.availability(.noAlbum)]).matches(track()))
        #expect(SearchFilter(tokens: [.availability(.notAnalysed)]).matches(track(energy: nil)))
        #expect(SearchFilter(tokens: [.availability(.linkedToSoundCloud)]).matches(track(original: "soundcloud://123")))
        #expect(!SearchFilter(tokens: [.availability(.inNoPlaylist)]).matches(track(), isInAnyPlaylist: { _ in true }))
        #expect(SearchFilter(tokens: [.availability(.inNoPlaylist)]).matches(track(), isInAnyPlaylist: { _ in false }))
    }

    @Test func aLinkFiltersNothing() {
        let filter = SearchFilter(text: "https://soundcloud.com/a/b")
        #expect(filter.isLink)
        #expect(filter.isEmpty)
        #expect(filter.hasInput)
    }

    @Test func namesAndCapabilities() {
        let filter = SearchFilter(text: "warm up genre:techno", tokens: [.availability(.local)])
        #expect(filter.matchesName("Warm-up — Up to the top"))
        #expect(filter.applicable(to: .names).allTokens.isEmpty)
        #expect(filter.applicable(to: .names).text == "warm up")
        #expect(filter.ignoredTokens(for: .names).count == 2)
        #expect(filter.ignoredTokens(for: .tracks).isEmpty)
        #expect(filter.applicable(to: .none).isEmpty)
    }

    @Test func onlineQueryUsesWordsAndTextValues() {
        let filter = SearchFilter(text: "remix bpm:120", tokens: [.artist("Overmono"), .availability(.local)])
        #expect(filter.onlineQuery == "remix Overmono")
    }
}

@Suite("Link suggestions")
struct LinkSuggestionTests {
    @Test func youtubeVideoIsATrackWithoutTheTimestamp() {
        #expect(LinkSuggestion.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
                == .track(source: .youtube, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        if case .track(.youtube, _) = LinkSuggestion.classify("https://youtu.be/abc123?t=300") {} else {
            Issue.record("youtu.be is a YouTube track")
        }
    }

    @Test func playlistsAndSets() {
        #expect(LinkSuggestion.classify("https://www.youtube.com/playlist?list=PLx")
                == .playlist(source: .youtube, url: "https://www.youtube.com/playlist?list=PLx"))
        #expect(LinkSuggestion.classify("https://soundcloud.com/artist/sets/name")
                == .playlist(source: .soundcloud, url: "https://soundcloud.com/artist/sets/name"))
        #expect(LinkSuggestion.classify("https://open.spotify.com/playlist/37i9")
                == .playlist(source: .spotify, url: "https://open.spotify.com/playlist/37i9"))
        #expect(LinkSuggestion.classify("https://soundcloud.com/artist/track-name")
                == .track(source: .soundcloud, url: "https://soundcloud.com/artist/track-name"))
    }

    @Test func otherLinksAreUnsupported() {
        #expect(LinkSuggestion.classify("https://bandcamp.com/album/x") == .unsupported(host: "bandcamp.com", url: "https://bandcamp.com/album/x"))
        #expect(LinkSuggestion.classify("https://cdn.example.com/a.mp3")?.source == nil)
        #expect(LinkSuggestion.classify("https://open.spotify.com/track/6rq")?.source == nil)
    }

    @Test func textIsNotALink() {
        #expect(LinkSuggestion.classify("kanye west run away") == nil)
        #expect(LinkSuggestion.classify("") == nil)
        #expect(LinkSuggestion.classify("https://x.com/a b") == nil)
        #expect(!LinkSuggestion.isLink("youtube.com/watch?v=x"))
    }

    @Test func copyFollowsTheDesign() {
        let track = LinkSuggestion.track(source: .youtube, url: "https://www.youtube.com/watch?v=Zx3kQpL0v9E")
        #expect(track.header == "Link · YouTube")
        #expect(track.actionTitle(nil) == "Download track from YouTube")
        let metadata = LinkMetadata(title: "Overmono – Good Lies (Official Video)", durationSeconds: 222)
        #expect(track.actionTitle(metadata) == "Download track from YouTube — “Overmono – Good Lies (Official Video)”")
        #expect(track.detail(metadata) == "youtube.com/watch?v=Zx3kQpL0v9E · 3:42")
        let playlist = LinkSuggestion.playlist(source: .soundcloud, url: "https://soundcloud.com/o/sets/d")
        #expect(playlist.header == "Link · SoundCloud playlist")
        #expect(playlist.actionTitle(LinkMetadata(trackCount: 44)) == "Import playlist from SoundCloud… (44 tracks)")
        #expect(LinkSuggestion.unsupported(host: "bandcamp.com", url: "https://bandcamp.com").header == "Link · bandcamp.com")
        #expect(LinkSuggestion.time(3734) == "1:02:14")
    }
}

@Suite("Recent searches")
struct RecentSearchStoreTests {
    private func store(_ id: String? = "lib") throws -> (RecentSearchStore, UserDefaults, String) {
        let suite = "mlm.tests.recent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (RecentSearchStore(defaults: defaults, libraryID: { id }), defaults, suite)
    }

    @Test func keepsFiveNewestFirstWithoutDuplicates() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for word in ["a", "b", "c", "d", "e", "f"] { store.record(SearchFilter(text: word)) }
        store.record(SearchFilter(text: "D"))
        #expect(store.load().map(\.text) == ["D", "f", "e", "c", "b"])
    }

    @Test func keepsTokensAndIsPerLibrary() throws {
        let (store, defaults, suite) = try store("one")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(SearchFilter(text: "", tokens: [.genre("Techno"), .availability(.notDownloaded)]))
        #expect(store.load().first?.tokens == [.genre("Techno"), .availability(.notDownloaded)])
        #expect(RecentSearchStore(defaults: defaults, libraryID: { "two" }).load().isEmpty)
        #expect(RecentSearchStore.key(libraryID: nil) == "search.recent.default")
    }

    @Test func linksAndEmptySearchesAreNotRemembered() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(SearchFilter(text: "https://youtu.be/x"))
        store.record(SearchFilter(text: "  "))
        #expect(store.load().isEmpty)
    }
}
