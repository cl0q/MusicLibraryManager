import Testing
import Foundation
@testable import MLM

@Suite("PlaylistMetadataMemoTests")
struct PlaylistMetadataMemoTests {

    @Test func sameKeyLoadsOnce() async throws {
        var cache: [Int64: SyncService.PlaylistTrackMemoEntry] = [:]
        var loadCount = 0
        let expected = SyncService.PlaylistTrackMemoEntry(exists: true, artist: "Artist", title: "Title", albumArtist: "AlbumArtist")

        for _ in 0..<14 {
            let result = try await SyncService.memoizedMetadata(key: Int64(42), in: &cache) {
                loadCount += 1
                return expected
            }
            #expect(result == expected)
        }

        #expect(loadCount == 1)
    }

    @Test func distinctKeysEachLoadOnce() async throws {
        var cache: [Int64: SyncService.PlaylistTrackMemoEntry] = [:]
        var loadCount = 0

        for i in 0..<5 {
            _ = try await SyncService.memoizedMetadata(key: Int64(i), in: &cache) {
                loadCount += 1
                return SyncService.PlaylistTrackMemoEntry(exists: true, artist: "A\(i)", title: "T\(i)", albumArtist: nil)
            }
        }

        #expect(loadCount == 5)
        #expect(cache.count == 5)
    }

    @Test func absentEntryIsMemoised() async throws {
        var cache: [Int64: SyncService.PlaylistTrackMemoEntry] = [:]
        var loadCount = 0
        let absent = SyncService.PlaylistTrackMemoEntry(exists: false, artist: "a", title: "t", albumArtist: nil)

        for _ in 0..<14 {
            let result = try await SyncService.memoizedMetadata(key: Int64(99), in: &cache) {
                loadCount += 1
                return absent
            }
            #expect(result.exists == false)
        }

        #expect(loadCount == 1)
    }

    @Test func cachedValuesIdenticalAcrossLookups() async throws {
        var cache: [Int64: SyncService.PlaylistTrackMemoEntry] = [:]
        let entry = SyncService.PlaylistTrackMemoEntry(exists: true, artist: "MixedCase", title: "Song", albumArtist: "Band")

        let first = try await SyncService.memoizedMetadata(key: Int64(1), in: &cache) { entry }
        let second = try await SyncService.memoizedMetadata(key: Int64(1), in: &cache) {
            SyncService.PlaylistTrackMemoEntry(exists: true, artist: "DIFFERENT", title: "DIFFERENT", albumArtist: "DIFFERENT")
        }

        #expect(first == second)
        #expect(second.artist == "MixedCase")
        #expect(second.albumArtist == "Band")
    }
}
