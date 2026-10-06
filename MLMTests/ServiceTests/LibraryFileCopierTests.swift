import Foundation
import Testing
@testable import MLM

/// Import Files or Folder… copies files from outside the library folder into its organised
/// layout (W3-ADD, settings.html ST-LIB.E12, PATTERN-DND.N09) — and never touches an original.
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

    /// Tags as the file name says: `Artist - Title.mp3`.
    private func copier(root: URL) -> LibraryFileCopier {
        LibraryFileCopier(libraryRoot: root, readMetadata: { url in
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
            return TrackMetadata(artist: parts[0], albumArtist: parts[0], album: "Album", title: parts.last ?? "",
                                 genre: nil, year: nil, bitrate: nil, duration: nil,
                                 format: url.pathExtension, originalPath: url.path)
        })
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
        #expect(try String(contentsOf: target, encoding: .utf8) == "audio-a1")
        #expect(try String(contentsOf: original, encoding: .utf8) == "audio-a1", "the original is untouched")
        #expect(target.path.hasSuffix(PathSanitizer.organizedPath(for: try await copier(root: root).readMetadata(original))),
                "the copy sits where the importer files it")
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

    @Test func anExistingFileIsNeverOverwritten() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let same = outside.appendingPathComponent("A - Same.mp3")
        let different = outside.appendingPathComponent("B - Other.mp3")
        try write("same", to: same)
        try write("new bytes", to: different)
        try write("same", to: root.appendingPathComponent("A/Album/Same.mp3"))
        try write("old bytes", to: root.appendingPathComponent("B/Album/Other.mp3"))

        let placement = await copier(root: root).place([same, different])

        #expect(placement.alreadyCopied == 1)
        #expect(placement.toImport == [root.appendingPathComponent("A/Album/Same.mp3")])
        #expect(placement.notCopied.map(\.file) == [different])
        #expect(placement.notCopied.first?.reason == "A different file named “Other.mp3” is already in the library folder")
        #expect(try String(contentsOf: root.appendingPathComponent("B/Album/Other.mp3"), encoding: .utf8) == "old bytes")
    }

    @Test func twoFilesForOneNameCopyOnlyTheFirst() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let first = outside.appendingPathComponent("one/A - Song.mp3")
        let second = outside.appendingPathComponent("two/A - Song.mp3")
        try write("1", to: first)
        try write("2", to: second)

        let placement = await copier(root: root).place([first, second])
        #expect(placement.copied == 1)
        #expect(placement.notCopied.map(\.file) == [second])
        #expect(try String(contentsOf: root.appendingPathComponent("A/Album/Song.mp3"), encoding: .utf8) == "1")
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
}
