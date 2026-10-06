import Foundation
import GRDB
import Testing
@testable import MLM

/// Import Files or Folder… and Finder drops copy files from outside the library folder into its
/// organised layout (W3-ADD, settings.html ST-LIB.E12, PATTERN-DND.N09) — and never touch an
/// original. Review H2, H3, S3–S5.
@Suite("Copy into the library folder")
struct LibraryFileCopierTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-copier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func canonical(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? url.path
    }

    /// Tags as the file name says: `Artist - Title.mp3`.
    private func copier(root: URL, known: Set<String> = [], wait: @escaping @Sendable () async -> Bool = { false }) -> LibraryFileCopier {
        LibraryFileCopier(libraryRoot: root, readMetadata: { url in
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
            return TrackMetadata(artist: parts[0], albumArtist: parts[0], album: "Album", title: parts.last ?? "",
                                 genre: nil, year: nil, bitrate: nil, duration: nil,
                                 format: url.pathExtension, originalPath: url.path)
        }, knownPaths: { keys in Set(keys).intersection(known) }, waitForLibraryFolder: wait)
    }

    @Test func filesFromOutsideAreCopiedIntoTheOrganisedLayoutAndOriginalsStay() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let original = outside.appendingPathComponent("Hessle - A1.mp3")
        try write("audio-a1", to: original)

        let placement = await copier(root: root).place([original])

        let target = root.appendingPathComponent("Hessle/Album/A1.mp3")
        #expect(placement.toImport == [target])
        #expect(placement.copied == 1)
        #expect(placement.importedPath[original.path] == target.path)
        #expect(try read(target) == "audio-a1")
        #expect(try read(original) == "audio-a1", "the original is untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(leftovers == ["A1.mp3"], "no temporary copy is left behind")
    }

    @Test func filesInsideTheLibraryFolderAreImportedWhereTheyAre() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("Loose/Someone - Song.flac")
        try write("x", to: inside)

        let placement = await copier(root: root).place([inside])
        #expect(placement.toImport == [inside])
        #expect(placement.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Someone").path))
    }

    /// H3: a file that already is a track (by `original_path`, any letter case) is neither
    /// copied nor imported again.
    @Test func aFileThatAlreadyIsATrackIsNotCopiedAgain() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("Known - Song.mp3")
        try write("x", to: file)

        let placement = await copier(root: root, known: [LibraryFileCopier.asciiLowercased(file.path)]).place([file])
        #expect(placement.alreadyInLibrary == 1)
        #expect(placement.toImport.isEmpty)
        #expect(placement.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Known").path))
    }

    /// H3 on a case-insensitive volume: the identical file already sits there under another
    /// letter case — its on-disk (canonical) path is used, and a track with that path is reused.
    @Test func theSameFileUnderAnotherLetterCaseIsMatchedByItsCanonicalPath() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? true
        try #require(!caseSensitive, "needs a case-insensitive volume (the default macOS one)")
        let onDisk = root.appendingPathComponent("a/album/same.mp3")
        try write("same", to: onDisk)
        let source = outside.appendingPathComponent("A - Same.mp3")
        try write("same", to: source)

        let fresh = await copier(root: root).place([source])
        #expect(fresh.alreadyCopied == 1)
        #expect(fresh.toImport.map(\.path) == [canonical(onDisk)], "never a second spelling of one file")

        let known = await copier(root: root, known: [LibraryFileCopier.asciiLowercased(canonical(onDisk))]).place([source])
        #expect(known.alreadyInLibrary == 1)
        #expect(known.toImport.isEmpty)
    }

    /// S5: a different file with the plain name gets the next free numbered name, reported.
    @Test func aDifferentFileWithTheSameNameGetsANumberedCopy() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let different = outside.appendingPathComponent("B - Other.mp3")
        try write("new bytes", to: different)
        try write("old bytes", to: root.appendingPathComponent("B/Album/Other.mp3"))

        let placement = await copier(root: root).place([different])

        let renamed = root.appendingPathComponent("B/Album/Other 2.mp3")
        #expect(placement.copied == 1)
        #expect(placement.toImport == [renamed])
        #expect(placement.renamed == [.init(copy: renamed, relativePath: "B/Album/Other 2.mp3")])
        #expect(try read(renamed) == "new bytes")
        #expect(try read(root.appendingPathComponent("B/Album/Other.mp3")) == "old bytes", "never overwritten")
    }

    /// S4 / S5: two chosen files for one name — the same bytes are one file; different bytes
    /// get a numbered copy.
    @Test func twoChosenFilesForOneName() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let first = outside.appendingPathComponent("one/A - Song.mp3")
        let same = outside.appendingPathComponent("two/A - Song.mp3")
        let other = outside.appendingPathComponent("three/A - Song.mp3")
        try write("1", to: first)
        try write("1", to: same)
        try write("2", to: other)

        let placement = await copier(root: root).place([first, same, other])
        #expect(placement.copied == 2)
        #expect(placement.alreadyCopied == 1)
        #expect(placement.notCopied.isEmpty)
        #expect(placement.importedPath[same.path] == placement.importedPath[first.path])
        #expect(try read(root.appendingPathComponent("A/Album/Song.mp3")) == "1")
        #expect(try read(root.appendingPathComponent("A/Album/Song 2.mp3")) == "2")
    }

    /// H2: Cancel stops before the next file and never reports 100 %.
    @Test func cancelStopsAndProgressNeverReachesTheEnd() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let files = (1...3).map { outside.appendingPathComponent("A - S\($0).mp3") }
        for file in files { try write(file.lastPathComponent, to: file) }
        let seen = Recorder()

        let placement = await copier(root: root).place(files, progress: { done, _ in seen.add(done) },
                                                       isCancelled: { seen.values.count > 1 })
        #expect(placement.wasCancelled)
        #expect(placement.copied == 2)
        #expect(placement.notReached == 1)
        #expect(!seen.values.contains(3), "no 100 % before the cancel")
    }

    /// S3: the library folder's drive is away — the copying waits, then stops with one cause.
    @Test func anUnreachableLibraryFolderStopsWithOneCause() async throws {
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: outside) }
        let root = outside.appendingPathComponent("gone", isDirectory: true)
        let files = (1...3).map { outside.appendingPathComponent("A - S\($0).mp3") }
        for file in files { try write("x", to: file) }

        let placement = await copier(root: root, wait: { false }).place(files)
        #expect(placement.notCopied.isEmpty, "no failure per file")
        #expect(placement.notReached == 3)
        #expect(placement.stopCause == "The library folder can’t be reached")

        let back = await copier(root: root, wait: {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return true
        }).place(files)
        #expect(back.copied == 3, "after the wait it goes on")
    }

    @Test func aFullDiskIsRecognised() {
        #expect(LibraryFileCopier.isDiskFull(CocoaError(.fileWriteOutOfSpace)))
        #expect(LibraryFileCopier.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(!LibraryFileCopier.isDiskFull(CocoaError(.fileWriteNoPermission)))
    }

    @Test func insideMeansUnderTheFolderNotANamePrefix() {
        let root = URL(fileURLWithPath: "/Volumes/Music/Library")
        #expect(LibraryFileCopier.isInside(URL(fileURLWithPath: "/Volumes/Music/Library/a.mp3"), root: root))
        #expect(!LibraryFileCopier.isInside(URL(fileURLWithPath: "/Volumes/Music/Library 2/a.mp3"), root: root))
    }

    @Test func theUndoConfirmationSaysTheFilesStay() {
        #expect(ShellActions.copiedImportMessage(imported: 4, copied: 4)
                == "Imported 4 tracks · 4 files copied into the library folder (Undo keeps the files)")
        #expect(ShellActions.copiedImportMessage(imported: 1, copied: 0) == "Imported 1 track")
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        func add(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

/// H2 end to end: a Cancel during copying imports what was copied and says so.
@Suite("Copying import operation")
@MainActor
struct CopyingImportOperationTests {
    actor RecordingImports: ImportServicing {
        private(set) var imported: [[URL]] = []
        func importDirectory(_ directory: URL, onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?) async throws -> ImportService.ImportResult {
            ImportService.ImportResult(succeeded: 0, failed: 0, skipped: 0, failures: [], totalScanned: 0, cancelled: false, committed: 0)
        }
        func importFiles(_ audioFiles: [URL], onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?) async throws -> ImportService.ImportResult {
            imported.append(audioFiles)
            return ImportService.ImportResult(succeeded: audioFiles.count, failed: 0, skipped: 0, failures: [],
                                              totalScanned: audioFiles.count, cancelled: false, committed: audioFiles.count)
        }
    }

    @Test func aCancelDuringCopyingImportsWhatWasCopied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-copyop-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-copyop-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let files = (1...3).map { outside.appendingPathComponent("A - S\($0).mp3") }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }

        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let imports = RecordingImports()
        let viewModel = ImportViewModel(importService: imports, configRepository: ConfigRepository(database: try DatabaseManager.inMemory()),
                                        activity: center)
        let gate = ImportTestGate()
        let copier = LibraryFileCopier(libraryRoot: root, readMetadata: { url in
            if url.lastPathComponent == "A - S2.mp3" { await gate.wait() }
            return TrackMetadata(artist: "A", albumArtist: "A", album: "Album",
                                 title: url.deletingPathExtension().lastPathComponent, genre: nil, year: nil,
                                 bitrate: nil, duration: nil, format: "mp3", originalPath: url.path)
        })
        let run = Task { await viewModel.importFilesCopyingIntoLibrary(files, title: "Import 3 files", copier: copier) }
        await waitUntil { gate.isWaiting }
        let operation = try #require(center.activeOperations.first)
        center.cancel(operation.id)
        gate.open()
        let outcome = try #require(await run.value)

        #expect(outcome.placement.wasCancelled)
        #expect(await imports.imported.first?.count == 2, "the copies are imported")
        let ended = try #require(center.operation(id: operation.id))
        #expect(ended.state == .cancelled)
        #expect(ended.result?.statusSentence == "2 copied and imported, 1 not copied")
    }
}
