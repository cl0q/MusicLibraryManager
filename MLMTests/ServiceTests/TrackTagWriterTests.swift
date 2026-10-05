import Foundation
import Testing
@testable import MLM

/// `TrackTagWriter` on audio files generated in a temporary folder (never a real library):
/// per format a round trip proving the tags changed while audio packets, duration, cover art
/// and unrelated tags stayed; the original untouched on every simulated failure.
@Suite("TrackTagWriter", .serialized)
struct TrackTagWriterTests {
    private typealias F = TagTestFixtures

    private func writer(_ tools: any TagToolRunner = LiveTagToolRunner()) -> TrackTagWriter {
        TrackTagWriter(tools: tools)
    }

    private struct RoundTrip {
        let outcome: TagWriteOutcome
        let before: [String: String]
        let after: [String: String]
        let hashesBefore: [String]
        let hashesAfter: [String]
        let durationBefore: Double?
        let durationAfter: Double?
        let strays: [String]
    }

    private func roundTrip(
        _ file: URL,
        root: URL,
        values: [TrackTagField: String?],
        expectedFiles: Set<String>
    ) async throws -> RoundTrip {
        let probeBefore = try await F.probe(file)
        let hashesBefore = try await F.hashes(of: file)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: root, values: values))
        let probeAfter = try await F.probe(file)
        return RoundTrip(
            outcome: outcome,
            before: probeBefore.tags,
            after: probeAfter.tags,
            hashesBefore: hashesBefore,
            hashesAfter: try await F.hashes(of: file),
            durationBefore: probeBefore.duration,
            durationAfter: probeAfter.duration,
            strays: try F.strayFiles(in: file.deletingLastPathComponent(), expected: expectedFiles)
        )
    }

    private static let edits: [TrackTagField: String?] = [
        .title: "New Title",
        .genre: "Techno",
        .year: "2019",
        .albumArtist: "Various",
        .album: nil, // remove
    ]

    private func expectRoundTrip(_ trip: RoundTrip, keeps unrelated: [String: String], bpmKey: String?) {
        #expect(trip.outcome == .written)
        #expect(trip.after["title"] == "New Title")
        #expect(trip.after["genre"] == "Techno")
        #expect(trip.after["date"] == "2019")
        #expect(trip.after["album_artist"] == "Various")
        #expect(trip.after["album"] == nil, "an empty album is written as no album tag")
        for (key, value) in unrelated {
            #expect(trip.after[key] == value, "unrelated tag \(key) kept")
        }
        if let bpmKey { #expect(trip.after[bpmKey.lowercased()] == "128") }
        #expect(trip.hashesBefore == trip.hashesAfter, "audio and cover packets unchanged")
        #expect(trip.hashesAfter.contains { $0.contains(",v,") }, "the cover is still there")
        #expect(trip.durationBefore == trip.durationAfter)
        #expect(trip.strays.isEmpty, "no temporary copy left: \(trip.strays)")
    }

    // MARK: Round trips per format

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func m4aWithPNGCoverRoundTrips() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let cover = try await F.cover(in: folder, png: true)
        let file = try await F.audio(.m4aAAC, in: folder, cover: cover, tags: [
            "title": "Old", "artist": "Artist", "album": "Old Album", "composer": "Bach", "comment": "keep me",
        ])
        var values = Self.edits
        values[.bpm] = "128" // M4A can't take BPM: silently not written
        let trip = try await roundTrip(file, root: folder, values: values, expectedFiles: ["track.m4a", "cover.png"])
        expectRoundTrip(trip, keeps: ["artist": "Artist", "composer": "Bach", "comment": "keep me"], bpmKey: nil)
        #expect(trip.after["major_brand"]?.hasPrefix("M4A") == true, "still an M4A (ipod muxer)")
        #expect(try await F.probe(file).streams.contains { $0.type == "video" && $0.attachedPicture })
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func m4aALACWithJPEGCoverRoundTrips() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let cover = try await F.cover(in: folder, png: false)
        let file = try await F.audio(.m4aALAC, in: folder, cover: cover, tags: ["title": "Old", "artist": "Artist", "album": "A"])
        let trip = try await roundTrip(file, root: folder, values: Self.edits, expectedFiles: ["track.m4a", "cover.jpg"])
        expectRoundTrip(trip, keeps: ["artist": "Artist"], bpmKey: nil)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func mp3RoundTripsAndKeepsID3v23AndCustomFrames() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let cover = try await F.cover(in: folder, png: false)
        let file = try await F.audio(.mp3, in: folder, cover: cover, tags: [
            "title": "Old", "artist": "Artist", "album": "Old Album", "composer": "Bach", "MY_CUSTOM": "x",
        ])
        #expect(TrackTagWriter.id3Version(of: file) == 3)
        var values = Self.edits
        values[.bpm] = "128"
        let trip = try await roundTrip(file, root: folder, values: values, expectedFiles: ["track.mp3", "cover.jpg"])
        expectRoundTrip(trip, keeps: ["artist": "Artist", "composer": "Bach", "my_custom": "x"], bpmKey: "TBPM")
        #expect(TrackTagWriter.id3Version(of: file) == 3, "the tag keeps its ID3v2 version")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func mp3WithID3v1KeepsIt() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let file = try await F.audio(.mp3, in: folder, tags: ["title": "Old", "artist": "Artist"], extra: ["-write_id3v1", "1"])
        #expect(TrackTagWriter.hasID3v1(file))
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.genre: "House"]))
        #expect(outcome == .written)
        #expect(TrackTagWriter.hasID3v1(file))
        #expect(try await F.tags(of: file)["genre"] == "House")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func flacRoundTripsWithCustomComments() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let cover = try await F.cover(in: folder, png: true)
        let file = try await F.audio(.flac, in: folder, cover: cover, tags: [
            "title": "Old", "artist": "Artist", "album": "Old Album", "composer": "Bach", "MYTAG": "hello",
        ])
        var values = Self.edits
        values[.bpm] = "128"
        let trip = try await roundTrip(file, root: folder, values: values, expectedFiles: ["track.flac", "cover.png"])
        expectRoundTrip(trip, keeps: ["artist": "Artist", "composer": "Bach", "mytag": "hello"], bpmKey: "BPM")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func onlyFieldsTheFormatCantTakeWriteNothing() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let file = try await F.audio(.m4aAAC, in: folder, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: file)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.bpm: "128"]))
        #expect(outcome == .nothingToWrite)
        #expect(try Data(contentsOf: file) == bytes)
    }

    // MARK: Refusals — the original stays byte for byte

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aRewriteThatWouldDropATagIsRefused() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        // A free-form MP4 key ffmpeg reads but can't write back.
        let file = try await F.audio(.m4aAAC, in: folder, tags: ["title": "Old", "MYCUSTOM": "zzz"], extra: ["-movflags", "use_metadata_tags"])
        #expect(try await F.tags(of: file)["mycustom"] == "zzz")
        let bytes = try Data(contentsOf: file)
        let outcome = await writer().write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        guard case .failed(.verificationFailed(let detail)) = outcome else {
            Issue.record("expected a verification failure, got \(outcome)")
            return
        }
        #expect(detail.contains("mycustom"))
        #expect(try Data(contentsOf: file) == bytes, "original untouched")
        #expect(try F.strayFiles(in: folder, expected: ["track.m4a"]).isEmpty)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aTruncatedCopyIsRefused() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let file = try await F.audio(.flac, in: folder, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: file)
        let damaging = ScriptedTagToolRunner(after: { _, arguments in
            guard let output = ScriptedTagToolRunner.rewriteOutput(arguments),
                  let data = try? Data(contentsOf: output) else { return }
            try? data.prefix(data.count / 2).write(to: output)
        })
        let outcome = await writer(damaging).write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        guard case .failed(.verificationFailed) = outcome else {
            Issue.record("expected a verification failure, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try F.strayFiles(in: folder, expected: ["track.flac"]).isEmpty)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aFailingReplaceLeavesTheOriginal() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let file = try await F.audio(.mp3, in: folder, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: file)
        var failing = writer()
        failing.replace = { _, _ in throw TagTestFixtures.Failure(description: "simulated rename failure") }
        let outcome = await failing.write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        guard case .failed(.replaceFailed) = outcome else {
            Issue.record("expected a replace failure, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try F.strayFiles(in: folder, expected: ["track.mp3"]).isEmpty)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aFailingFFmpegLeavesTheOriginal() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let file = try await F.audio(.mp3, in: folder, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: file)
        let failing = ScriptedTagToolRunner(before: { _, arguments in
            guard let output = ScriptedTagToolRunner.rewriteOutput(arguments) else { return nil }
            try? Data("partial".utf8).write(to: output) // a half-written copy
            return ScriptedTagToolRunner.result(exit: 1, stderr: "simulated")
        })
        let outcome = await writer(failing).write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        guard case .failed(.rewriteFailed) = outcome else {
            Issue.record("expected a rewrite failure, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try F.strayFiles(in: folder, expected: ["track.mp3"]).isEmpty)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func m4aFallsBackToTheMP4MuxerOnExit234() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let cover = try await F.cover(in: folder, png: true)
        let file = try await F.audio(.m4aAAC, in: folder, cover: cover, tags: ["title": "Old"])
        let hashes = try await F.hashes(of: file)
        let refusingIpod = ScriptedTagToolRunner(before: { _, arguments in
            guard ScriptedTagToolRunner.rewriteOutput(arguments) != nil,
                  let index = arguments.firstIndex(of: "-f"), arguments[index + 1] == "ipod" else { return nil }
            return ScriptedTagToolRunner.result(exit: 234, stderr: "Could not write header (incorrect codec parameters ?)")
        })
        let outcome = await writer(refusingIpod).write(TagWriteRequest(fileURL: file, libraryRoot: folder, values: [.title: "New"]))
        #expect(outcome == .written)
        #expect(try await F.tags(of: file)["title"] == "New")
        #expect(try await F.hashes(of: file) == hashes, "audio and PNG cover kept")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func neverWritesOutsideTheLibraryFolder() async throws {
        let root = try F.makeFolder("root")
        let elsewhere = try F.makeFolder("elsewhere")
        defer { F.remove(root); F.remove(elsewhere) }
        let outside = try await F.audio(.mp3, in: elsewhere, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: outside)
        #expect(await writer().write(TagWriteRequest(fileURL: outside, libraryRoot: root, values: [.title: "New"])) == .failed(.outsideLibraryFolder))
        // A link inside the folder pointing out of it.
        let link = root.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(await writer().write(TagWriteRequest(fileURL: link, libraryRoot: root, values: [.title: "New"])) == .failed(.outsideLibraryFolder))
        // `..` out of the folder.
        let dotted = root.appendingPathComponent("../\(elsewhere.lastPathComponent)/track.mp3")
        #expect(await writer().write(TagWriteRequest(fileURL: dotted, libraryRoot: root, values: [.title: "New"])) == .failed(.outsideLibraryFolder))
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func unsupportedFormatsAreSkippedWithAReason() async throws {
        let folder = try F.makeFolder()
        defer { F.remove(folder) }
        let wav = try await F.audio(.wav, in: folder, tags: ["title": "Old"])
        let bytes = try Data(contentsOf: wav)
        let outcome = await writer().write(TagWriteRequest(fileURL: wav, libraryRoot: folder, values: [.title: "New"]))
        #expect(outcome == .failed(.unsupportedFormat("WAV")))
        #expect(TagWriteFailure.unsupportedFormat("WAV").reason == "WAV isn’t supported")
        #expect(TagWriteFailure.unsupportedFormat("WAV").isPermanent)
        #expect(try Data(contentsOf: wav) == bytes)
    }

    @Test func missingFileFolderAndToolsAreReported() async throws {
        let root = try F.makeFolder()
        defer { F.remove(root) }
        let missing = root.appendingPathComponent("gone.mp3")
        #expect(await writer().write(TagWriteRequest(fileURL: missing, libraryRoot: root, values: [.title: "x"])) == .failed(.fileMissing))
        let goneRoot = root.appendingPathComponent("not-there", isDirectory: true)
        #expect(await writer().write(TagWriteRequest(fileURL: goneRoot.appendingPathComponent("a.mp3"), libraryRoot: goneRoot, values: [.title: "x"]))
                == .failed(.libraryFolderUnreachable))
        let file = root.appendingPathComponent("a.mp3")
        try Data("not really audio".utf8).write(to: file)
        let noTools = ScriptedTagToolRunner(missingTools: [.ffmpeg])
        #expect(await writer(noTools).write(TagWriteRequest(fileURL: file, libraryRoot: root, values: [.title: "x"])) == .failed(.toolMissing))
        #expect(try Data(contentsOf: file) == Data("not really audio".utf8))
    }

    // MARK: Values from the database

    @Test func valuesNeverCarryPlaceholdersOrProvenance() {
        var track = Track(artist: "Skee Mask", album: "unknown album", title: "Glass Circuit", format: "m4a",
                          originalPath: "https://soundcloud.com/skee/glass-circuit")
        track.albumArtist = ""
        track.genre = "  "
        track.year = 0
        track.bpm = 128
        let all = TrackTagWriter.values(for: track, fields: Set(TrackTagField.allCases))
        #expect(all[.album] == .some(nil), "a placeholder album is written as no album tag")
        #expect(all[.albumArtist] == .some(nil))
        #expect(all[.genre] == .some(nil))
        #expect(all[.year] == .some(nil))
        #expect(all[.bpm] == .some("128"))
        #expect(all[.title] == .some("Glass Circuit"))
        for value in all.values.compactMap({ $0 }) {
            #expect(!value.lowercased().contains("soundcloud"), "never the source")
        }
        track.album = "SoundCloud Likes"
        #expect(TrackTagWriter.values(for: track, fields: [.album])[.album] == .some(nil))
        track.album = "Compro"
        #expect(TrackTagWriter.values(for: track, fields: [.album]) == [.album: "Compro"], "only the stale fields")
        track.artist = "unknown artist"
        #expect(TrackTagWriter.values(for: track, fields: [.artist]).isEmpty, "a placeholder artist isn't written")
    }

    @Test func verifyRejectsAnyDifferenceButTheRequestedTags() {
        let stream = TrackTagWriter.ProbeStream(index: 0, type: "audio", codec: "mp3", sampleRate: "44100", channels: 2, attachedPicture: false)
        let before = TrackTagWriter.ProbeResult(duration: 3, tags: ["title": "a", "composer": "Bach", "encoder": "LAME"], streams: [stream])
        let good = TrackTagWriter.ProbeResult(duration: 3, tags: ["title": "b", "composer": "Bach", "encoder": "Lavf"], streams: [stream])
        let changes: [(key: String, value: String?)] = [("title", "b")]
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: good, afterHashes: ["h"], changes: changes, format: .mp3) == nil)
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: good, afterHashes: ["x"], changes: changes, format: .mp3) != nil)
        let lost = TrackTagWriter.ProbeResult(duration: 3, tags: ["title": "b"], streams: [stream])
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: lost, afterHashes: ["h"], changes: changes, format: .mp3) != nil)
        let shorter = TrackTagWriter.ProbeResult(duration: 2.5, tags: good.tags, streams: [stream])
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: shorter, afterHashes: ["h"], changes: changes, format: .mp3) != nil)
        let recoded = TrackTagWriter.ProbeResult(duration: 3, tags: good.tags,
                                                 streams: [.init(index: 0, type: "audio", codec: "aac", sampleRate: "44100", channels: 2, attachedPicture: false)])
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: recoded, afterHashes: ["h"], changes: changes, format: .mp3) != nil)
        let unread = TrackTagWriter.ProbeResult(duration: 3, tags: ["title": "a", "composer": "Bach"], streams: [stream])
        #expect(TrackTagWriter.verify(before: before, beforeHashes: ["h"], after: unread, afterHashes: ["h"], changes: changes, format: .mp3) != nil)
    }
}
