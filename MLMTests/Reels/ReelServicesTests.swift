import Foundation
import Testing
@testable import MLM

// MARK: - Guesses (provenance, ordering, split rules)

@Suite("ReelGuessesTests")
struct ReelGuessesTests {
    @Test func fileNameSplitsWithTodaysDelimiters() {
        #expect(ArtistTitleSplit.split("Overmono - So U Kno") == (artist: "Overmono", title: "So U Kno"))
        #expect(ArtistTitleSplit.split("Overmono – So U Kno") == (artist: "Overmono", title: "So U Kno"))
        #expect(ArtistTitleSplit.split("Overmono | So U Kno") == (artist: "Overmono", title: "So U Kno"))
        // The bare dash is the last resort.
        #expect(ArtistTitleSplit.split("Overmono-SoUKno") == (artist: "Overmono", title: "SoUKno"))
        // Nothing to split: no artist, the whole text is the title.
        #expect(ArtistTitleSplit.split("IMG_4471") == (artist: "", title: "IMG_4471"))
        #expect(!ArtistTitleSplit.canSplit("IMG_4471"))
        #expect(ArtistTitleSplit.canSplit("Overmono - So U Kno"))
    }

    @Test func aFileNameOnlyGuessesWhenItSplits() {
        let guess = ReelGuesses.fileNameGuess("Overmono - So U Kno.mp4")
        #expect(guess?.artist == "Overmono")
        #expect(guess?.title == "So U Kno")
        #expect(guess?.source == .fileName)
        #expect(ReelGuesses.fileNameGuess("IMG_4471.mov") == nil)
    }

    @Test func mergeOrdersShazamThenTextThenFileNameAndKeepsProvenance() {
        let text = [
            ReelTextCandidate(artist: "Fred again", title: "delilah", score: 100, stillOffset: 4),
            ReelTextCandidate(artist: "Other", title: "Thing", score: 80, stillOffset: 9),
        ]
        let guesses = ReelGuesses.merge(
            fileName: "Bicep - Glue.mp4",
            shazam: ReelShazamMatch(artist: "Fred again..", title: "Delilah", offset: 7),
            text: text)
        #expect(guesses.map(\.source) == [.shazam, .text, .text, .fileName])
        #expect(guesses.map(\.source.word) == ["Shazam", "Text in video", "Text in video", "File name"])
        #expect(guesses[0].provenanceLine == "Shazam · matched at 0:07")
        #expect(guesses[1].provenanceLine == "Text in video · still at 0:04")
        #expect(guesses[3].provenanceLine == "File name")
        #expect(guesses[0].confidence > guesses[1].confidence && guesses[1].confidence > guesses[3].confidence)
    }

    @Test func theSameSongFromSeveralSourcesIsListedOnceUnderTheFirst() {
        let guesses = ReelGuesses.merge(
            fileName: "Overmono - So U Kno.mp4",
            shazam: ReelShazamMatch(artist: "overmono", title: "so u kno", offset: nil),
            text: [ReelTextCandidate(artist: "Overmono", title: "So U Kno", score: 100, stillOffset: 1)])
        #expect(guesses.count == 1)
        #expect(guesses[0].source == .shazam)
    }

    @Test func guessesNeverWriteFieldsAndRoundTripThroughJSON() {
        let guesses = ReelGuesses.merge(fileName: "A - B.mp4", shazam: ReelShazamMatch(artist: "X", title: "Y", offset: 3), text: [])
        let json = ReelGuesses.encode(guesses)
        #expect(json?.contains("\"source\":\"shazam\"") == true)
        #expect(json?.contains("\"source\":\"fileName\"") == true)
        #expect(ReelGuesses.decode(json) == guesses)
        #expect(ReelGuesses.encode([]) == nil)
        #expect(ReelGuesses.decode("not json").isEmpty)
        #expect(ReelGuesses.decode(nil).isEmpty)
    }

    @Test func textCandidatesFollowTodaysRules() {
        let texts = ["Fred again.. - Delilah", "@fredagain", "1:23", "Originalton - Someone", "Overmono • So U Kno", "x - y", "gefällt mir"]
        let candidates = ReelTextParsing.candidates(in: texts)
        let pairs = candidates.map { "\($0.artist)|\($0.title)" }
        #expect(pairs.contains("Fred again..|Delilah"))
        #expect(pairs.contains("Overmono|So U Kno"))
        // Handles, times, interface text and one-letter halves are out.
        #expect(!pairs.contains("x|y"))
        #expect(candidates.count == 2)
        // Longer pairs first when the score ties.
        #expect(candidates[0].artist == "Fred again..")
    }

    @Test func fragmentsAreCleanedFilteredAndLongestFirst() {
        let fragments = ReelTextParsing.fragments(from: [
            ["actual life 3", "@fred", "00:12"], ["pull me out of this (Original Audio)", "actual life 3"],
        ])
        #expect(fragments == ["pull me out of this", "actual life 3"])
    }

    @Test func timecodeFormats() {
        #expect(ReelGuesses.timecode(7.9) == "0:07")
        #expect(ReelGuesses.timecode(62) == "1:02")
    }

    @Test func keyframeOffsetsAreTenAtFiveToNinetyFivePercent() {
        let offsets = KeyframeGeometry.offsets(duration: 100, count: 10)
        #expect(offsets.count == 10)
        #expect(abs(offsets[0] - 5) < 0.0001 && abs(offsets[9] - 95) < 0.0001)
        #expect(KeyframeGeometry.offsets(duration: 100, count: 50).count == 10)
        #expect(KeyframeGeometry.offsets(duration: 0, count: 10).isEmpty)
    }
}

// MARK: - Search (per-source grouping)

@Suite("ReelSearchTests")
struct ReelSearchTests {
    private func results(dab: [DabTrack] = [], qobuz: [SquidWtfClient.SquidTrack] = [], youtube: [YouTubeTrack] = []) -> UnifiedSearchResults {
        UnifiedSearchResults(dabTracks: dab, squidTracks: qobuz, soundCloudTracks: [], youtubeTracks: youtube)
    }

    @Test func everySourceGetsAGroupAndAnEmptyOneSaysNoMatches() {
        let youtube = YouTubeTrack(id: "abc", title: "Delilah", duration: 252, url: nil, uploader: "Fred again..")
        let groups = ReelSearch.groups(from: results(youtube: [youtube]))
        #expect(groups.map(\.source) == [.soundCloud, .youtube, .dab, .qobuz])
        #expect(groups.map(\.countWord) == ["No matches", "1", "No matches", "No matches"])
        let row = groups[1].results[0]
        #expect(row.artist == "Fred again..")
        #expect(row.durationSeconds == 252)
        #expect(row.sourceURL == "https://www.youtube.com/watch?v=abc")
        #expect(row.detailLine == "Fred again.. · 4:12")
    }

    @Test func allEmptyIsZeroMatchesNotOffline() {
        let groups = ReelSearch.groups(from: results())
        #expect(groups.allSatisfy { $0.results.isEmpty })
        #expect(!ReelSearchOutcome.groups(groups).hasMatches)
        #expect(!ReelSearchOutcome.offline.hasMatches)
    }

    @Test func queryJoinsTheFilledFields() {
        #expect(ReelSearch.query(artist: " Fred again.. ", title: "Delilah") == "Fred again.. Delilah")
        #expect(ReelSearch.query(artist: "", title: "Delilah") == "Delilah")
        #expect(ReelSearch.query(artist: "Fred", title: "  ") == "Fred")
    }

    @Test func sourcesAreNamedInTheSentences() {
        #expect(ReelSource.sentenceList == "SoundCloud, YouTube, DAB and Qobuz")
        #expect(ReelSearch.searchingSentence("a b") == "Searching SoundCloud, YouTube, DAB and Qobuz for “a b”…")
    }

    @Test func liveSearchReportsOfflineBeforeSearching() async {
        let search = LiveReelSearch(run: { _ in Issue.record("must not search while offline"); return UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: []) },
                                    isOnline: { false })
        #expect(await search.search(artist: "a", title: "b") == .offline)
    }

    @Test func liveSearchGroupsWhenOnline() async {
        let search = LiveReelSearch(run: { query in
            #expect(query == "a b")
            return UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: [])
        }, isOnline: { true })
        let outcome = await search.search(artist: "a", title: "b")
        guard case .groups(let groups) = outcome else { Issue.record("expected groups"); return }
        #expect(groups.count == 4)
    }
}

// MARK: - Import (temporary folders)

@Suite("ReelImporterTests")
struct ReelImporterTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func foldersAreScannedWithSubfoldersForMp4AndMov() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("a.mp4"))
        try touch(root.appendingPathComponent("sub/b.MOV"))
        try touch(root.appendingPathComponent("sub/deeper/c.mov"))
        try touch(root.appendingPathComponent("notes.txt"))
        try touch(root.appendingPathComponent(".hidden.mp4"))
        let scan = ReelImporter.scan([root])
        #expect(scan.videos.map(\.lastPathComponent) == ["a.mp4", "b.MOV", "c.mov"])
        #expect(scan.emptyFolders.isEmpty)
    }

    @Test func aFolderWithoutVideosIsNamed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Documents")
        try touch(folder.appendingPathComponent("readme.txt"))
        let scan = ReelImporter.scan([folder])
        #expect(scan.videos.isEmpty)
        #expect(scan.emptyFolders == ["Documents"])
        #expect(ReelImporter.noVideosSentence("Documents") == "No videos in “Documents”")
    }

    @Test func filesAreTakenOnceAndOtherFilesAreRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("v.mp4")
        let text = root.appendingPathComponent("n.txt")
        try touch(video)
        try touch(text)
        let scan = ReelImporter.scan([video, root, text, root.appendingPathComponent("missing.mp4")])
        #expect(scan.videos.count == 1)
        #expect(scan.refused == ["n.txt"])
        #expect(ReelImporter.notAVideoSentence(["n.txt"]) == "Can’t add “n.txt” — it isn’t a video or a folder")
    }

    @Test func recordsSkipListedVideosAndPrefillFromAFileNameThatSplits() {
        let urls = [URL(fileURLWithPath: "/r/Overmono - So U Kno.mp4"), URL(fileURLWithPath: "/r/IMG_1.mov"), URL(fileURLWithPath: "/r/old.mp4")]
        var counter = 0
        let records = ReelImporter.records(for: urls, excluding: ["/r/old.mp4"], now: Date(timeIntervalSince1970: 10)) {
            counter += 1
            return "id\(counter)"
        }
        #expect(records.map(\.id) == ["id1", "id2"])
        #expect(records[0].artist == "Overmono" && records[0].title == "So U Kno" && records[0].state == .identified)
        #expect(ReelGuesses.decode(records[0].guessesJSON).first?.source == .fileName)
        #expect(records[1].artist.isEmpty && records[1].title.isEmpty && records[1].state == .new)
    }
}

// MARK: - Links

@Suite("ReelLinkFetcherTests")
struct ReelLinkFetcherTests {
    @Test func theThreeHostsAreRecognised() {
        #expect(ReelLinkParser.parse("https://www.instagram.com/reel/C9xQ2mTtP4k/")?.source == .instagram)
        #expect(ReelLinkParser.parse("https://instagram.com/reels/C9xQ2mTtP4k")?.source == .instagram)
        #expect(ReelLinkParser.parse("https://www.tiktok.com/@berlin.rave.diary/video/7421")?.source == .tiktok)
        #expect(ReelLinkParser.parse("https://vm.tiktok.com/ZMabc123/")?.source == .tiktok)
        #expect(ReelLinkParser.parse("https://www.youtube.com/shorts/abcDEF12345")?.source == .youtubeShorts)
        #expect(ReelLinkParser.parse("https://m.youtube.com/shorts/abcDEF12345")?.source == .youtubeShorts)
    }

    @Test func otherLinksAreRefused() {
        #expect(ReelLinkParser.parse("https://www.youtube.com/watch?v=abc") == nil)
        #expect(ReelLinkParser.parse("https://www.instagram.com/someone/") == nil)
        #expect(ReelLinkParser.parse("https://example.com/reel/abc") == nil)
        #expect(ReelLinkParser.parse("https://notinstagram.com/reel/abc") == nil)
        #expect(ReelLinkParser.parse("ftp://instagram.com/reel/abc") == nil)
        #expect(ReelLinkParser.parse("not a link") == nil)
        #expect(ReelLinkParser.parse("") == nil)
        #expect(ReelLinkParser.refusal == "That isn’t an Instagram, TikTok or YouTube Shorts link.")
    }

    @Test func aPastedTextWithSeveralWordsFindsTheLink() {
        #expect(ReelLinkParser.firstLink(in: "look https://www.instagram.com/reel/abc123/ now")?.source == .instagram)
        #expect(ReelLinkParser.firstLink(in: "nothing here") == nil)
    }

    @Test func helpTextIsTheMockupsVerbatim() {
        #expect(ReelLinkParser.helpText == "Instagram, TikTok and YouTube Shorts links. The video is saved to ~/Downloads/Reels and appears as New. If the link needs a sign-in, MLM says so here.")
    }

    @Test func aMissingToolIsSaidInWords() async {
        let fetcher = YtDlpReelFetcher(executable: { nil })
        let link = ReelLinkParser.parse("https://www.instagram.com/reel/abc123/")!
        await #expect(throws: ReelFetchError.toolMissing) {
            _ = try await fetcher.fetch(link, into: FileManager.default.temporaryDirectory)
        }
    }

    @Test func signInWallsAndOtherErrorsAreTold() {
        #expect(YtDlpReelFetcher.error(fromStderr: "ERROR: [Instagram] abc: Login required", timedOut: false) == .needsSignIn)
        #expect(YtDlpReelFetcher.error(fromStderr: "WARNING: x\nERROR: [TikTok] Unable to extract video", timedOut: false)
            == .failed("[TikTok] Unable to extract video"))
        #expect(YtDlpReelFetcher.error(fromStderr: "", timedOut: true) == .failed("the download took too long"))
        #expect(ReelFetchError.needsSignIn.errorDescription == "the link needs a sign-in")
    }
}

// MARK: - Audio

@Suite("ReelAudioIdentifierTests")
struct ReelAudioIdentifierTests {
    @Test func offlineErrorsAreToldApartFromNoMatch() {
        #expect(ReelAudioIdentifier.isOffline(URLError(.notConnectedToInternet)))
        #expect(ReelAudioIdentifier.isOffline(URLError(.networkConnectionLost)))
        let wrapped = NSError(domain: "SHErrorDomain", code: 202, userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        #expect(ReelAudioIdentifier.isOffline(wrapped))
        #expect(!ReelAudioIdentifier.isOffline(nil))
        #expect(!ReelAudioIdentifier.isOffline(NSError(domain: "SHErrorDomain", code: 201)))
        #expect(ReelAudioIdentifier.listenSeconds == 12)
    }
}
