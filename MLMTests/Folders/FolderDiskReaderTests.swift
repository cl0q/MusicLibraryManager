import Foundation
import Testing
@testable import MLM

/// Reading folders from disk (ported from `DiskFolderScannerTests`): one level for an opened
/// folder, the whole library folder in the background; hidden, linked and MLM's own temporary
/// files never show. Temporary folders only.
@Suite("Folders disk reader (W3-FOLD)")
struct FolderDiskReaderTests {
    @Test func managedLayoutUsesOnlyUserFacingFolderNames() {
        #expect(ManagedLibraryLayout.folderNames == [
            "Downloads (SoundCloud)",
            "Downloads (YouTube)",
            "Transcode originals",
        ])
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_folders_\(UUID().uuidString)")
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
        FileManager.default.createFile(atPath: parent.appendingPathComponent(name).path, contents: Data([1]))
    }

    @Test func aListingHasFoldersAndAudioFilesSortedLikeFinder() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "Zebra")
        try mkdir(root, "Album 10")
        try mkdir(root, "Album 9")
        try mkdir(root, ".hidden")
        touch(root, "song.mp3")
        touch(root, "track.flac")
        touch(root, "notes.txt")
        touch(root, "cover.jpg")
        touch(root, ".DS_Store")
        touch(root, ".song.mp3.mlm-copy-ABC")
        try mkdir(root, "fake.mp3")  // a folder named like an audio file is a folder

        let listing = try #require(FolderDiskReader.list(root).listing)
        #expect(listing.subfolders == ["Album 9", "Album 10", "fake.mp3", "Zebra"])
        #expect(listing.audioFiles == ["song.mp3", "track.flac"])
    }

    @Test func aListingDoesNotRecurseAndSkipsLinks() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        touch(root, "top.mp3")
        let sub = try mkdir(root, "SubFolder")
        touch(sub, "nested.mp3")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: sub)

        let listing = try #require(FolderDiskReader.list(root).listing)
        #expect(listing.audioFiles == ["top.mp3"])
        #expect(listing.subfolders == ["SubFolder"])
    }

    @Test func aMissingFolderIsUnreadableWithAPlainReason() {
        let result = FolderDiskReader.list(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        guard case .unreadable(let reason) = result else {
            Issue.record("expected unreadable")
            return
        }
        #expect(reason == "the folder isn’t there any more")
    }

    @Test func theWalkReadsEveryFolderKeyedByItsRelativePath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try mkdir(root, "A")
        let b = try mkdir(a, "B")
        touch(b, "deep.flac")
        touch(root, "loose.mp3")

        let walked = FolderDiskReader.walk(root, isCancelled: { false })
        #expect(Set(walked.keys) == ["", "A", "A/B"])
        #expect(walked[""]?.listing?.audioFiles == ["loose.mp3"])
        #expect(walked["A/B"]?.listing?.audioFiles == ["deep.flac"])
    }

    @Test func aCancelledWalkStops() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try mkdir(root, "A")
        #expect(FolderDiskReader.walk(root, isCancelled: { true }).isEmpty)
    }

    @Test func theLibrarySearchFindsFoldersByName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = try mkdir(root, "Sets")
        try mkdir(sets, "Dekmantel 2026")
        try mkdir(root, ".Dek hidden")
        let matches = try await DiskFolderScanner().searchDirectories(under: root, query: "dek")
        #expect(matches.map(\.name) == ["Dekmantel 2026"])
    }
}
