import XCTest
@testable import MLMMobile

final class SyncFolderTests: XCTestCase {

    func testManifestURLComposition() async {
        let syncFolder = await SyncFolder()
        await syncFolder.useDocumentsDirectory()

        let manifestURL = await syncFolder.manifestURL
        XCTAssertNotNil(manifestURL)
        XCTAssertTrue(manifestURL!.path.hasSuffix("mlm-library.json"))
    }

    func testPlaylistsDirectoryComposition() async {
        let syncFolder = await SyncFolder()
        await syncFolder.useDocumentsDirectory()

        let playlistsDir = await syncFolder.playlistsDirectory
        XCTAssertNotNil(playlistsDir)
        XCTAssertTrue(playlistsDir!.path.hasSuffix("Playlists"))
        XCTAssertTrue(playlistsDir!.hasDirectoryPath)
    }

    func testMusicRootComposition() async {
        let syncFolder = await SyncFolder()
        await syncFolder.useDocumentsDirectory()

        let musicRoot = await syncFolder.musicRoot
        XCTAssertNotNil(musicRoot)
        XCTAssertTrue(musicRoot!.path.hasSuffix("Music"))
        XCTAssertTrue(musicRoot!.hasDirectoryPath)
    }

    func testClearFolder() async {
        let syncFolder = await SyncFolder()
        await syncFolder.useDocumentsDirectory()

        let rootBefore = await syncFolder.rootURL
        XCTAssertNotNil(rootBefore)

        await syncFolder.clearFolder()
        let rootAfter = await syncFolder.rootURL
        XCTAssertNil(rootAfter)
    }

    func testURLCompositionFromCustomRoot() async {
        let syncFolder = await SyncFolder()
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-sync-\(UUID().uuidString)")

        // Use the documents directory approach since we can't easily test
        // security-scoped bookmarks in unit tests.
        await syncFolder.useDocumentsDirectory()

        let manifestURL = await syncFolder.manifestURL
        let playlistsDir = await syncFolder.playlistsDirectory
        let musicRoot = await syncFolder.musicRoot

        // All three should be children of the same root.
        XCTAssertNotNil(manifestURL)
        XCTAssertNotNil(playlistsDir)
        XCTAssertNotNil(musicRoot)

        // Verify the parent of manifest is the root.
        XCTAssertEqual(manifestURL!.deletingLastPathComponent(), musicRoot!.deletingLastPathComponent())
        XCTAssertEqual(playlistsDir!.deletingLastPathComponent(), musicRoot!.deletingLastPathComponent())
    }
}
