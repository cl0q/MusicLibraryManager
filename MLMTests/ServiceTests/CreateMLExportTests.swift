import Foundation
import Testing
@testable import MLM

/// Export Create ML Training Set… (W3-GEN, ST-STUDIO-EXPORT): the plan said before the start,
/// the run as an Activity operation with honest counts and a real Cancel, and files written only
/// into the chosen folder — library files are only read.
@Suite("Create ML export", .serialized)
@MainActor
struct CreateMLExportTests {
    private func track(_ id: Int64, genre: String?, artist: String = "Artist", title: String? = nil,
                       file: String? = "Artist/x.m4a", duration: Int = 300) -> Track {
        var track = Track(artist: artist, album: "", title: title ?? "Title \(id)", format: "m4a", originalPath: "/nowhere/\(id).m4a")
        track.id = id
        track.genre = genre
        track.organizedPath = file
        track.duration = duration
        if file == nil { track.downloadStatus = nil }
        return track
    }

    // MARK: Plan

    @Test func planIncludesGenresWithEnoughTracksAndCountsWhatIsSkipped() {
        var tracks: [Track] = []
        for id in 1...5 { tracks.append(track(Int64(id), genre: id == 1 ? "techno" : "Techno")) }
        tracks.append(track(6, genre: "Techno", file: nil))           // not downloaded
        for id in 10...11 { tracks.append(track(Int64(id), genre: "House")) }
        tracks.append(track(20, genre: nil))
        let plan = CreateMLExportPlan.make(tracks: tracks, minimumTracks: 3)
        #expect(plan.included.map(\.name) == ["Techno"])
        #expect(plan.included.first?.trackCount == 6)
        #expect(plan.leftOut.map(\.name) == ["House"])
        #expect(plan.includedTrackCount == 6)
        #expect(plan.leftOutTrackCount == 2)
        #expect(plan.items.count == 5)
        #expect(plan.notDownloaded == 1)
        #expect(plan.estimatedBytes == 5 * 300 * 248 * 1_000 / 8)
        #expect(Set(plan.items.map(\.folder)) == ["Techno"])
        #expect(CreateMLExportPlan.make(tracks: tracks, minimumTracks: 50).included.isEmpty)
        #expect(CreateMLExportPlan.make(tracks: tracks, minimumTracks: 50).warning
                == "No genre has that many tracks. Lower the minimum.")
        #expect(plan.warning.hasPrefix("1 of these tracks is not downloaded and will be skipped. The export needs about "))
    }

    @Test func fileNamesAreSafeAndUnique() {
        let tracks = [
            track(1, genre: "Drum/Bass", artist: "A:B", title: "Same"),
            track(2, genre: "Drum/Bass", artist: "a:b", title: "same"),
            track(3, genre: "drum/bass", artist: ".hidden", title: "x?y"),
        ]
        let plan = CreateMLExportPlan.make(tracks: tracks, minimumTracks: 1)
        #expect(plan.items.map(\.folder) == ["Drum_Bass", "Drum_Bass", "Drum_Bass"])
        #expect(plan.items.map(\.fileBaseName) == ["A_B - Same", "a_b - same 2", "hidden - x_y"])
        #expect(CreateMLExportPlan.sanitized("   ") == "Untitled")
    }

    // MARK: Run

    private func folder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MLM-createml-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func plan(_ count: Int, skipped: Int = 0) -> CreateMLExportPlan {
        var tracks = (1...count).map { track(Int64($0), genre: "Techno") }
        tracks += (0..<skipped).map { track(Int64(1_000 + $0), genre: "Techno", file: nil) }
        return CreateMLExportPlan.make(tracks: tracks, minimumTracks: 1)
    }

    @Test func runCountsEveryOutcomeAndEndsTheOperation() async throws {
        let destination = try folder("run")
        defer { try? FileManager.default.removeItem(at: destination) }
        let activity = ActivityCenter(scheduler: ManualActivityScheduler())
        let exporter = CreateMLExporter()
        let writer = CreateMLExportFileWriter { item, destination in
            switch item.track.id {
            case 2: return .failed(.notConverted)
            case 3: return .failed(.fileMissing)
            default:
                let folder = destination.appendingPathComponent(item.folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: folder.appendingPathComponent(item.fileBaseName + ".m4a").path, contents: Data([1]))
                return .exported
            }
        }
        let ended = GenreTestBox<CreateMLExportSummary?>(nil)
        let task = try #require(exporter.run(plan(6, skipped: 2), into: destination, writer: writer, workers: 3,
                                             activity: activity) { ended.value = $0 })
        let summary = await task.value
        #expect(summary.exported == 4)
        #expect(summary.skipped == 2)
        #expect(summary.failedNotConverted == 1 && summary.failedMissing == 1)
        #expect(summary.sentence == "Exported 4 tracks, 2 skipped, 2 failed")
        #expect(!summary.wasCancelled)
        while exporter.isRunning { await Task.yield() }
        #expect(ended.value == summary)
        let operation = try #require(activity.operations.first { $0.kind == .createMLExport })
        #expect(operation.state == .completed)
        #expect(operation.result?.counts.map(\.count) == [4, 2, 2])
        let written = try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Techno").path)
        #expect(written.count == 4)
    }

    @Test func cancelStartsNoNewFile() async throws {
        let destination = try folder("cancel")
        defer { try? FileManager.default.removeItem(at: destination) }
        let activity = ActivityCenter(scheduler: ManualActivityScheduler())
        let exporter = CreateMLExporter()
        let started = GenreTestBox(0)
        let gate = AsyncGate()
        let writer = CreateMLExportFileWriter { _, _ in
            started.update { $0 += 1 }
            await gate.wait()
            return .exported
        }
        let task = try #require(exporter.run(plan(10), into: destination, writer: writer, workers: 2, activity: activity))
        while started.value < 2 { await Task.yield() }
        let running = try #require(activity.operations.first { $0.kind == .createMLExport })
        #expect(running.controls.cancelStyle == .afterThisFile, "honest: files in flight finish")
        // Activity's Cancel is the exporter's.
        running.controls.cancel?()
        while !task.isCancelled { await Task.yield() }
        await gate.open()
        let summary = await task.value
        #expect(summary.wasCancelled)
        #expect(summary.exported == 2, "the two files in flight finished, nothing new started")
        #expect(summary.sentence.hasPrefix("Export cancelled — exported 2 tracks"))
        while exporter.isRunning { await Task.yield() }
        #expect(activity.operations.first { $0.kind == .createMLExport }?.state == .cancelled)
    }

    @Test func aSecondExportWaitsForTheFirst() async throws {
        let exporter = CreateMLExporter()
        let activity = ActivityCenter(scheduler: ManualActivityScheduler())
        let gate = AsyncGate()
        let writer = CreateMLExportFileWriter { _, _ in await gate.wait(); return .exported }
        let destination = FileManager.default.temporaryDirectory
        let first = exporter.run(plan(1), into: destination, writer: writer, workers: 1, activity: activity)
        #expect(first != nil)
        #expect(exporter.run(plan(1), into: destination, writer: writer, workers: 1, activity: activity) == nil)
        await gate.open()
        _ = await first?.value
    }

    // MARK: The file writer: only the chosen folder is written

    @Test func theWriterCopiesTheCachedFileIntoTheDestinationAndTouchesNothingElse() async throws {
        let library = try folder("library")
        let cacheDir = try folder("cache")
        let destination = try folder("destination")
        defer { [library, cacheDir, destination].forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = library.appendingPathComponent("Artist/x.m4a")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("library file".utf8).write(to: source)
        let cache = TranscodeCache(cacheDir: cacheDir)
        let cached = cache.cachePath(trackId: 1, bitrateKbps: 248)
        try Data("cached aac".utf8).write(to: cached)
        let sourceDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let cacheListing = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)

        let writer = CreateMLExportFileWriter.files(libraryRoot: { library.path }, cache: cache)
        let item = try #require(CreateMLExportPlan.make(tracks: [track(1, genre: "Techno")], minimumTracks: 1).items.first)
        #expect(await writer.write(item, destination) == .exported)
        let exported = destination.appendingPathComponent("Techno/Artist - Title 1.m4a")
        #expect(try Data(contentsOf: exported) == Data("cached aac".utf8))
        // Again: the earlier export's file is replaced, still only inside the destination.
        #expect(await writer.write(item, destination) == .exported)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Techno").path) == ["Artist - Title 1.m4a"])

        #expect(try Data(contentsOf: source) == Data("library file".utf8), "the library file is only read")
        #expect(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sourceDate)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path) == cacheListing)
        #expect(try Data(contentsOf: cached) == Data("cached aac".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == ["Artist"])
    }

    @Test func aMissingFileFailsWithoutWritingAnything() async throws {
        let destination = try folder("missing")
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = CreateMLExportFileWriter.files(libraryRoot: { "/nonexistent-library" }, cache: nil)
        let item = try #require(CreateMLExportPlan.make(tracks: [track(1, genre: "Techno")], minimumTracks: 1).items.first)
        #expect(await writer.write(item, destination) == .failed(.fileMissing))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
