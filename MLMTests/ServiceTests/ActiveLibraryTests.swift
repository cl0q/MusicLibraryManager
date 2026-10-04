import Testing
import Foundation
@testable import MLM

/// A3 Wave 2 (Step-0 decision 5): caches keyed by track ID are namespaced per library,
/// so libraries never read each other's waveforms or transcodes.
@Suite("ActiveLibrary (A3 Wave 2)")
struct ActiveLibraryTests {

    private let base = URL(fileURLWithPath: "/tmp/caches/waveforms")

    private func library(_ id: String, package: URL? = nil) -> ActiveLibrary {
        ActiveLibrary(
            databaseURL: URL(fileURLWithPath: "/tmp/\(id)/music_library.db"),
            libraryId: id,
            packageURL: package)
    }

    @Test func cachesAreNamespacedByLibraryId() {
        let a = library("lib-a").namespacedCacheDirectory(in: base)
        let b = library("lib-b").namespacedCacheDirectory(in: base)
        #expect(a == base.appendingPathComponent("lib-a"))
        #expect(a != b)
    }

    @Test func databaseWithoutIdUsesTheSharedFolder() {
        #expect(library("").namespacedCacheDirectory(in: base) == base)
    }

    @Test func waveformFilesDifferPerLibraryForTheSameTrack() {
        let fileURL = URL(fileURLWithPath: "/music/song.flac")
        let a = PlaybackViewModel.waveformCacheURL(
            in: library("lib-a").namespacedCacheDirectory(in: base), trackID: 42, fileURL: fileURL)
        let b = PlaybackViewModel.waveformCacheURL(
            in: library("lib-b").namespacedCacheDirectory(in: base), trackID: 42, fileURL: fileURL)
        #expect(a.lastPathComponent == "42.bin")
        #expect(a != b)
    }

    @Test func defaultCacheRootsAreUnchanged() {
        #expect(ActiveLibrary.defaultWaveformCacheRoot.path.hasSuffix("Library/Caches/com.musiclibrary.app/waveforms"))
        #expect(ActiveLibrary.defaultTranscodeCacheRoot.path.hasSuffix("Library/Caches/com.mlm.transcode_cache"))
    }

    @Test func legacyLayoutHasNoLibraryFile() {
        #expect(library("lib-a").isLegacyLayout)
        #expect(!library("lib-a", package: URL(fileURLWithPath: "/tmp/A.mlibm")).isLegacyLayout)
    }

    @Test func locationResolvesItsDatabase() {
        let package = URL(fileURLWithPath: "/tmp/A.mlibm")
        #expect(LibraryLocation.package(package).databaseURL == LibraryPackage.databaseURL(in: package))
        #expect(LibraryLocation.package(package).packageURL == package)
        let legacy = URL(fileURLWithPath: "/tmp/music_library.db")
        #expect(LibraryLocation.legacy(legacy).databaseURL == legacy)
        #expect(LibraryLocation.legacy(legacy).packageURL == nil)
    }
}
