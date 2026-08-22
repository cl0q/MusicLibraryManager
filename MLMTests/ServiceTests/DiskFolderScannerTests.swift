import Testing
import Foundation
@testable import MLM

struct DiskFolderScannerTests {

    @Test func managedLayoutUsesOnlyUserFacingFolderNames() {
        #expect(ManagedLibraryLayout.folderNames == [
            "Downloads (SoundCloud)",
            "Downloads (YouTube)",
            "Transcode originals",
        ])
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_scanner_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @discardableResult
    private func mkdir(_ parent: URL, _ name: String) throws -> URL {
        let dir = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ parent: URL, _ name: String) {
        FileManager.default.createFile(atPath: parent.appendingPathComponent(name).path, contents: nil)
    }

    // MARK: - scan: tree structure

    @Test func scanBuildsCorrectTreeForTestDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let artistA = try mkdir(root, "ArtistA")
        try mkdir(artistA, "Album1")
        try mkdir(artistA, "Album2")
        try mkdir(root, "ArtistB")

        let scanner = DiskFolderScanner()
        let nodes = try await scanner.scan(rootURL: root)

        #expect(nodes.count == 2)
        #expect(nodes.map(\.name).sorted() == ["ArtistA", "ArtistB"])

        let a = try #require(nodes.first(where: { $0.name == "ArtistA" }))
        #expect(a.children.count == 2)
        #expect(a.children.map(\.name).sorted() == ["Album1", "Album2"])

        let b = try #require(nodes.first(where: { $0.name == "ArtistB" }))
        #expect(b.children.isEmpty)
    }

    @Test func scanUsesFullPathAsNodeID() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "Folder")

        let scanner = DiskFolderScanner()
        let nodes = try await scanner.scan(rootURL: root)

        // Check that the ID is a full path ending with "/Folder" and uses the stable
        // canonical form (FileManager resolves /var → /private/var on macOS).
        let folderID = try #require(nodes.first?.id)
        #expect(folderID.hasSuffix("/Folder"))
        // The ID must be a prefix-extended form of the root path (possibly with /private prefix).
        #expect(URL(fileURLWithPath: folderID).deletingLastPathComponent().lastPathComponent == root.lastPathComponent)
    }

    @Test func scanSkipsHiddenDirectories() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "Visible")
        try mkdir(root, ".hidden")

        let scanner = DiskFolderScanner()
        let nodes = try await scanner.scan(rootURL: root)

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "Visible")
    }

    @Test func scanIgnoresFilesAtRootLevel() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "SubDir")
        touch(root, "song.mp3")
        touch(root, "readme.txt")

        let scanner = DiskFolderScanner()
        let nodes = try await scanner.scan(rootURL: root)

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "SubDir")
    }

    @Test func scanReturnsAlphabeticallySortedNodes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "Zebra")
        try mkdir(root, "Apple")
        try mkdir(root, "Mango")

        let scanner = DiskFolderScanner()
        let nodes = try await scanner.scan(rootURL: root)

        #expect(nodes.map(\.name) == ["Apple", "Mango", "Zebra"])
    }

    // MARK: - filesInDirectory

    @Test func filesInDirectoryListsOnlyAudioFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "song.mp3")
        touch(dir, "track.flac")
        touch(dir, "notes.txt")
        touch(dir, "cover.jpg")
        touch(dir, "album.m4a")

        let scanner = DiskFolderScanner()
        let files = try await scanner.filesInDirectory(dir)
        let names = files.map(\.lastPathComponent).sorted()

        #expect(names == ["album.m4a", "song.mp3", "track.flac"])
    }

    @Test func filesInDirectoryExcludesSubdirectories() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "song.mp3")
        // A directory whose name looks like an audio file — should be excluded.
        try mkdir(dir, "fake.mp3")

        let scanner = DiskFolderScanner()
        let files = try await scanner.filesInDirectory(dir)

        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "song.mp3")
    }

    @Test func filesInDirectoryDoesNotRecurse() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, "top.mp3")
        let sub = try mkdir(dir, "SubFolder")
        touch(sub, "nested.mp3")

        let scanner = DiskFolderScanner()
        let files = try await scanner.filesInDirectory(dir)

        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "top.mp3")
    }
}
