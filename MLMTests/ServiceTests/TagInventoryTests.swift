import Foundation
import Testing
@testable import MLM

/// W2-E review B2: the raw tag inventory and its allow-list. The parser and guard tests run
/// without ffmpeg (fixtures built byte by byte); the round trips through the writer need ffmpeg
/// and say so when it is missing. Every crafted item is either preserved exactly or refused.
@Suite("Tag inventory and allow-list")
struct TagInventoryTests {
    private typealias B = TagFixtureBytes
    private typealias F = TagTestFixtures

    private func mp3(_ tag: Data, tail: Data = Data()) throws -> TagInventory {
        try TagInventoryReader.mp3(DataByteSource(data: tag + B.infoFrame(delay: 576, padding: 1080) + tail))
    }

    // MARK: MP3 — pure

    @Test func allowListedID3FramesAreReadWithTheirValues() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3])
        let inventory = try mp3(B.id3(version: 3, frames: [
            ("TIT2", B.text("Glass Circuit")), ("TPE1", B.text("Skee Mask", encoding: 1)), ("TYER", B.text("2018")),
            ("TXXX", B.txxx("MusicBrainz Album Id", "abc")), ("APIC", B.apic(jpeg)), ("PRIV", B.latin1("owner") + Data([0, 1, 2])),
        ]))
        #expect(inventory.refusal == nil)
        #expect(inventory.id3Version == 3)
        #expect(inventory.value("ID3:TIT2") == "Glass Circuit")
        #expect(inventory.value("ID3:TPE1") == "Skee Mask", "UTF-16 decoded")
        #expect(inventory.value("ID3:TXXX:MusicBrainz Album Id") == "abc")
        #expect(inventory.value("ID3:APIC")?.hasPrefix("image/jpeg|3||sha256:") == true)
        #expect(inventory.items.contains { $0.key == "ID3:PRIV:owner" })
        #expect(inventory.gapless == "xing:576/1080", "LAME delay and padding")
    }

    @Test(arguments: [
        ("GEOB", B.geob("Serato Markers_"), "Serato markers"),
        ("GEOB", B.geob("Other Object"), "GEOB"),
        ("POPM", B.popm(), "a rating (POPM)"),
        ("UFID", B.ufid(), "a unique file identifier (UFID)"),
        ("COMM", B.comm("a comment"), "comments (COMM)"),
        ("USLT", B.uslt("la la"), "lyrics (USLT)"),
        ("WXXX", Data([0, 0]) + B.latin1("http://x"), "a web link (WXXX)"),
        ("TSOP", B.text("Sort"), "TSOP"), // v2.4-only frame in a v2.3 tag: ffmpeg moves it into TXXX
    ] as [(String, Data, String)])
    func framesMLMCantKeepAreRefusedInPlainWords(_ id: String, _ content: Data, _ reason: String) throws {
        let inventory = try mp3(B.id3(version: 3, frames: [("TIT2", B.text("T")), (id, content)]))
        #expect(inventory.refusal == reason)
    }

    @Test func structuresMLMCantKeepAreRefused() throws {
        #expect(try mp3(B.id3(version: 4, frames: [("TPE1", B.text("A\u{0}B", encoding: 3))])).refusal == "multiple values in TPE1")
        #expect(try mp3(B.id3(version: 3, frames: [("TIT2", B.text("A")), ("TIT2", B.text("B"))])).refusal == "duplicate TIT2 frames")
        #expect(try mp3(B.id3(version: 3, frames: [("TXXX", B.txxx("K", "1")), ("TXXX", B.txxx("K", "2"))])).refusal == "duplicate TXXX:K frames")
        #expect(try mp3(B.id3(version: 3, frames: [("TCON", B.text("(17)"))])).refusal == "a numeric genre (TCON)")
        #expect(try mp3(B.id3(version: 2, frames: [])).refusal == "an ID3v2.2 tag")
        #expect(try mp3(B.id3(version: 3, flags: 0x80, frames: [])).refusal == "an ID3 tag with unsynchronisation or an extended header")
        let v1 = B.id3v1(title: "T", artist: "A", album: "L", year: "2019", comment: "c", track: 3)
        #expect(try mp3(B.id3(version: 3, frames: []), tail: v1).refusal == "an ID3v1 comment or track number")
        let ape = Data("APETAGEX".utf8) + Data(repeating: 0, count: 24)
        #expect(try mp3(B.id3(version: 3, frames: []), tail: ape).refusal == "an APE tag")
        #expect(try mp3(B.id3(version: 3, frames: []), tail: Data("LYRICSBEGINxLYRICS200".utf8)).refusal == "a Lyrics3 tag")
    }

    @Test func aPlainID3v1IsAllowedAndRead() throws {
        let inventory = try mp3(B.id3(version: 3, frames: [("TIT2", B.text("T"))]), tail: B.id3v1(title: "T", artist: "A", album: "L", year: "2019"))
        #expect(inventory.refusal == nil)
        #expect(inventory.id3v1?["artist"] == "A" && inventory.id3v1?["year"] == "2019" && inventory.id3v1?["comment"] == "")
    }

    // MARK: FLAC — pure

    private let streamInfo = Data(repeating: 7, count: 34)

    @Test func flacBlocksAndCommentsMLMCantKeepAreRefused() throws {
        func inventory(_ blocks: [(UInt8, Data)]) throws -> TagInventory {
            try TagInventoryReader.flac(DataByteSource(data: B.flac(streamInfo: streamInfo, blocks: blocks, frames: Data([0xff, 0xf8]))))
        }
        #expect(try inventory([(3, B.seekTable)]).refusal == "a seek table")
        #expect(try inventory([(2, B.latin1("abcd") + Data([1]))]).refusal == "an APPLICATION block")
        #expect(try inventory([(5, Data(repeating: 0, count: 8))]).refusal == "a cue sheet")
        #expect(try inventory([(4, B.vorbisComments(["ARTIST=A", "ARTIST=B"]))]).refusal == "duplicate ARTIST comments")
        #expect(try inventory([(4, B.vorbisComments(["artist=A", "ARTIST=B"]))]).refusal == "duplicate ARTIST comments")
        #expect(try inventory([(4, B.vorbisComments(["COMMENT=hi"]))]).refusal == "a COMMENT comment")
        let allowed = try inventory([(4, B.vorbisComments(["TITLE=T", "MUSICBRAINZ_TRACKID=abc", "Mixed_Case=x"])), (6, B.flacPicture(Data([1, 2]))), (1, Data(repeating: 0, count: 10))])
        #expect(allowed.refusal == nil)
        #expect(allowed.value("VC:MUSICBRAINZ_TRACKID") == "abc" && allowed.value("VC:MIXED_CASE") == "x")
        #expect(allowed.value("FLAC:PICTURE")?.hasPrefix("3|image/png||sha256:") == true)
        #expect(allowed.items.contains { $0.key == "FLAC:STREAMINFO" })
        let id3First = try TagInventoryReader.flac(DataByteSource(data: B.id3(version: 3, frames: []) + Data("fLaC".utf8)))
        #expect(id3First.refusal == "an ID3 tag in front of the FLAC data")
    }

    // MARK: MP4 — pure

    @Test func mp4ItemsMLMCantKeepAreRefused() throws {
        func refusal(_ items: Data, extra: Data = Data()) throws -> String? {
            try TagInventoryReader.mp4(DataByteSource(data: B.bareMP4(items: items, extraMoov: extra))).refusal
        }
        let title = B.box("©nam", B.dataAtom(1, Data("T".utf8)))
        #expect(try refusal(title) == nil)
        #expect(try refusal(title + B.freeform(mean: "com.serato.dj", name: "markersv2", kind: 0, payload: Data([1, 2]))) == "Serato markers")
        #expect(try refusal(title + B.freeform(mean: "com.apple.iTunes", name: "iTunSMPB", kind: 1, payload: Data(" 0 840 1CA".utf8))) == "gapless information (iTunSMPB)")
        #expect(try refusal(title + B.freeform(mean: "com.apple.iTunes", name: "MusicBrainz Track Id", kind: 1, payload: Data("x".utf8))) == "----:MusicBrainz Track Id")
        #expect(try refusal(title + B.box("tmpo", B.dataAtom(21, Data([0, 128])))) == "BPM (tmpo)")
        #expect(try refusal(title + title) == "duplicate ©nam items")
        #expect(try refusal(title, extra: B.box("meta", Data([0, 0, 0, 0]))) == "MP4 metadata keys (mdta)")
        let inventory = try TagInventoryReader.mp4(DataByteSource(data: B.bareMP4(items: title + B.box("covr", B.dataAtom(13, Data([9]))))))
        #expect(inventory.value("MP4:©nam") == "T")
        #expect(inventory.value("MP4:covr")?.hasPrefix("t13:sha256:") == true)
    }

    @Test func theSameEditListInAnotherMovieTimescaleIsTheSameGapless() throws {
        let item = B.box("©nam", B.dataAtom(1, Data("T".utf8)))
        let a = try TagInventoryReader.mp4(DataByteSource(data: B.bareMP4(items: item, timescale: 44_100, segment: 132_300)))
        let b = try TagInventoryReader.mp4(DataByteSource(data: B.bareMP4(items: item, timescale: 4_410_000, segment: 13_230_000)))
        let c = try TagInventoryReader.mp4(DataByteSource(data: B.bareMP4(items: item, mediaTime: 2112)))
        #expect(a.gapless == b.gapless)
        #expect(a.gapless != c.gapless, "another priming is another gapless")
    }

    // MARK: Comparison — pure

    @Test func comparisonAllowsOnlyTheEditedAndVolatileItems() {
        var before = TagInventory()
        before.items = [.init(key: "ID3:TIT2", content: "Old"), .init(key: "ID3:TPE1", content: "A"), .init(key: "ID3:TSSE", content: "LAME")]
        var after = before
        after.items = [.init(key: "ID3:TIT2", content: "New"), .init(key: "ID3:TPE1", content: "A"), .init(key: "ID3:TSSE", content: "Lavf")]
        #expect(TagInventoryComparison.problem(before: before, after: after, expected: ["ID3:TIT2": "New"], editedV1: []) == nil)
        var lost = after
        lost.items.removeAll { $0.key == "ID3:TPE1" }
        #expect(TagInventoryComparison.problem(before: before, after: lost, expected: ["ID3:TIT2": "New"], editedV1: []) != nil)
        var changed = after
        changed.items[1] = .init(key: "ID3:TPE1", content: "a")
        #expect(TagInventoryComparison.problem(before: before, after: changed, expected: ["ID3:TIT2": "New"], editedV1: []) != nil)
        #expect(TagInventoryComparison.problem(before: before, after: after, expected: ["ID3:TIT2": "Other"], editedV1: []) != nil)
        var gapless = after
        gapless.gapless = "xing:0/0"
        #expect(TagInventoryComparison.problem(before: before, after: gapless, expected: ["ID3:TIT2": "New"], editedV1: []) != nil)
        var v1Before = before
        v1Before.id3v1 = ["title": "Old", "artist": "A"]
        var v1After = after
        v1After.id3v1 = ["title": "New", "artist": "B"]
        #expect(TagInventoryComparison.problem(before: v1Before, after: v1After, expected: ["ID3:TIT2": "New"], editedV1: ["title"]) == "ID3v1 artist changed")
    }

    // MARK: Through the writer (ffmpeg)

    private func writer() -> TrackTagWriter { TrackTagWriter() }

    /// Every allow-listed ID3 frame (both versions) comes through a write unchanged in value.
    @Test(.enabled(if: F.toolsAvailable, F.skipReason), arguments: [3, 4])
    func allowListedID3FramesRoundTrip(_ version: Int) async throws {
        let folder = try F.makeFolder("inventory")
        defer { F.remove(folder) }
        let plain = try Data(contentsOf: try await F.audio(.mp3, in: folder, name: "plain"))
        let jpeg = try Data(contentsOf: try await F.cover(in: folder, png: false))
        var frames: [(String, Data)] = [
            ("TIT2", B.text("Old")), ("TPE1", B.text("Artist", encoding: 1)), ("TALB", B.text("Album")), ("TPE2", B.text("AA")),
            ("TCON", B.text("Techno")), ("TBPM", B.text("128")), ("TRCK", B.text("3/12")), ("TPOS", B.text("1/2")),
            ("TCOM", B.text("Bach")), ("TKEY", B.text("Am")), ("TCOP", B.text("(c) X")), ("TPUB", B.text("Label")),
            ("TENC", B.text("Enc")), ("TIT3", B.text("Sub")), ("TSRC", B.text("USX")), ("TFLT", B.text("MPG/3")),
            ("TMED", B.text("CD")), ("TLAN", B.text("eng")), ("TOPE", B.text("Orig")),
            ("TXXX", B.txxx("MusicBrainz Album Id", "abc-123")), ("TXXX", B.txxx("Mixed", "x")),
            ("APIC", B.apic(jpeg)), ("PRIV", B.latin1("owner") + Data([0, 1, 2])),
        ]
        frames.append(version == 4 ? ("TDRC", B.text("2019-05-03")) : ("TYER", B.text("2019")))
        if version == 4 { frames += [("TSOP", B.text("Sort A")), ("TSOA", B.text("Sort L")), ("TSOT", B.text("Sort T")), ("TIT1", B.text("Grp"))] }
        let file = folder.appendingPathComponent("crafted.mp3")
        try B.retag(mp3: plain, with: B.id3(version: UInt8(version), frames: frames)).write(to: file)
        let before = try TagInventoryReader.read(fileURL: file, format: .mp3)
        #expect(before.refusal == nil)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        #expect(outcome == .written, "\(outcome)")
        let after = try TagInventoryReader.read(fileURL: file, format: .mp3)
        #expect(after.value("ID3:TIT2") == "New")
        let kept = before.items.filter { $0.key != "ID3:TIT2" && $0.key != "ID3:TSSE" }.sorted()
        #expect(after.items.filter { $0.key != "ID3:TIT2" && $0.key != "ID3:TSSE" }.sorted() == kept, "every other frame unchanged in value")
        #expect(after.gapless == before.gapless)
    }

    /// Each kind of tag data MLM can't keep: refused before anything is written.
    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func craftedMP3sWithDataMLMCantKeepAreRefusedUntouched() async throws {
        let folder = try F.makeFolder("inventory")
        defer { F.remove(folder) }
        let plain = try Data(contentsOf: try await F.audio(.mp3, in: folder, name: "plain"))
        let cases: [(String, Data, String)] = [
            ("geob", B.id3(version: 3, frames: [("TIT2", B.text("T")), ("GEOB", B.geob("Serato Markers2"))]), "Serato markers"),
            ("popm", B.id3(version: 3, frames: [("TIT2", B.text("T")), ("POPM", B.popm())]), "a rating (POPM)"),
            ("ufid", B.id3(version: 3, frames: [("TIT2", B.text("T")), ("UFID", B.ufid())]), "a unique file identifier (UFID)"),
            ("comm", B.id3(version: 3, frames: [("TIT2", B.text("T")), ("COMM", B.comm("hi"))]), "comments (COMM)"),
            ("uslt", B.id3(version: 3, frames: [("TIT2", B.text("T")), ("USLT", B.uslt("la"))]), "lyrics (USLT)"),
            ("multi", B.id3(version: 4, frames: [("TPE1", B.text("A\u{0}B", encoding: 3))]), "multiple values in TPE1"),
        ]
        for (name, tag, reason) in cases {
            let file = folder.appendingPathComponent("\(name).mp3")
            try B.retag(mp3: plain, with: tag).write(to: file)
            let bytes = try Data(contentsOf: file)
            let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
            #expect(outcome == .failed(.cannotPreserve(reason)), "\(name): \(outcome)")
            #expect(try Data(contentsOf: file) == bytes, "\(name) untouched")
        }
        #expect(TagWriteFailure.cannotPreserve("Serato markers").reason == "it contains tag data MLM can’t preserve (Serato markers)")
        #expect(TagWriteFailure.cannotPreserve("GEOB").isPermanent)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func anID3v1IsKeptAndUpdatedOnlyInTheEditedField() async throws {
        let folder = try F.makeFolder("inventory")
        defer { F.remove(folder) }
        let plain = try Data(contentsOf: try await F.audio(.mp3, in: folder, name: "plain"))
        let file = folder.appendingPathComponent("v1.mp3")
        let tag = B.id3(version: 3, frames: [("TIT2", B.text("Old")), ("TPE1", B.text("Artist")), ("TALB", B.text("Album")), ("TYER", B.text("2019")), ("TCON", B.text("Rock"))])
        try B.retag(mp3: plain, with: tag, appending: B.id3v1(title: "Old", artist: "Artist", album: "Album", year: "2019", genre: 17)).write(to: file)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        #expect(outcome == .written, "\(outcome)")
        let after = try TagInventoryReader.read(fileURL: file, format: .mp3)
        #expect(after.id3v1?["title"] == "New" && after.id3v1?["artist"] == "Artist" && after.id3v1?["genre"] == "17")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func craftedFLACsAreKeptExactlyOrRefused() async throws {
        let folder = try F.makeFolder("inventory")
        defer { F.remove(folder) }
        let parts = B.flacParts(try Data(contentsOf: try await F.audio(.flac, in: folder, name: "plain")))
        let png = try Data(contentsOf: try await F.cover(in: folder, png: true))
        // Refused: seek table, duplicate ARTIST, APPLICATION.
        let refused: [(String, [(UInt8, Data)], String)] = [
            ("seek", [(3, B.seekTable), (4, B.vorbisComments(["TITLE=T"]))], "a seek table"),
            ("dup", [(4, B.vorbisComments(["TITLE=T", "ARTIST=A", "ARTIST=B"]))], "duplicate ARTIST comments"),
            ("app", [(2, B.latin1("abcd") + Data([1, 2])), (4, B.vorbisComments(["TITLE=T"]))], "an APPLICATION block"),
        ]
        for (name, blocks, reason) in refused {
            let file = folder.appendingPathComponent("\(name).flac")
            try B.flac(streamInfo: parts.streamInfo, blocks: blocks, frames: parts.frames).write(to: file)
            let bytes = try Data(contentsOf: file)
            #expect(await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"])) == .failed(.cannotPreserve(reason)))
            #expect(try Data(contentsOf: file) == bytes)
        }
        // Kept: custom keys, DESCRIPTION, a picture, padding — all unchanged but the title.
        let file = folder.appendingPathComponent("kept.flac")
        try B.flac(streamInfo: parts.streamInfo, blocks: [
            (4, B.vorbisComments(["TITLE=Old", "ARTIST=A", "MUSICBRAINZ_TRACKID=abc", "Mixed_Case=x", "DESCRIPTION=d", "DATE=2019-05-03"])),
            (6, B.flacPicture(png)), (1, Data(repeating: 0, count: 64)),
        ], frames: parts.frames).write(to: file)
        let before = try TagInventoryReader.read(fileURL: file, format: .flac)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        #expect(outcome == .written, "\(outcome)")
        let after = try TagInventoryReader.read(fileURL: file, format: .flac)
        #expect(after.value("VC:TITLE") == "New")
        let skip: Set<String> = ["VC:TITLE", "VC:ENCODER"]
        #expect(after.items.filter { !skip.contains($0.key) }.sorted() == before.items.filter { !skip.contains($0.key) }.sorted())
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func anM4AWithABinaryFreeformAtomIsRefusedUntouched() async throws {
        let folder = try F.makeFolder("inventory")
        defer { F.remove(folder) }
        // ffmpeg without +faststart writes moov after mdat: atoms can be appended in place.
        let generated = try await F.audio(.m4aAAC, in: folder, name: "plain", tags: ["title": "Old"])
        let injected = try #require(B.injectIntoIlst(try Data(contentsOf: generated),
                                                     items: B.freeform(mean: "com.serato.dj", name: "markersv2", kind: 0, payload: Data([1, 2, 3]))))
        let file = folder.appendingPathComponent("serato.m4a")
        try injected.write(to: file)
        #expect(try TagInventoryReader.read(fileURL: file, format: .m4a).refusal == "Serato markers")
        #expect(await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"])) == .failed(.cannotPreserve("Serato markers")))
        #expect(try Data(contentsOf: file) == injected)
        // An allow-listed item injected the same way is kept.
        let kept = try #require(B.injectIntoIlst(try Data(contentsOf: generated), items: B.box("©grp", B.dataAtom(1, Data("Grp".utf8)))))
        let keptFile = folder.appendingPathComponent("kept.m4a")
        try kept.write(to: keptFile)
        #expect(await writer().write(TagWriteRequest(fileURL: keptFile, libraryRoot: folder, values: [.title: "New"])) == .written)
        #expect(try TagInventoryReader.read(fileURL: keptFile, format: .m4a).value("MP4:©grp") == "Grp")
    }
}
