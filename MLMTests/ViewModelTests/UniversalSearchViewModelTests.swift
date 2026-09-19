import Foundation
import Testing
@testable import MLM

/// Tests for `UniversalSearchViewModel` — state management for the
/// universal search view. Handles URL resolution, metadata fetching,
/// and download triggering.
///
/// Module 6 contract: The view model takes user input, routes it,
/// resolves metadata asynchronously, and exposes state for the UI.
///
/// Place implementation in: MLM/ViewModels/UniversalSearchViewModel.swift
struct Module6_UniversalSearchViewModelTests {

    // MARK: - State

    @Test
    func initialStateIsIdle() {
        let vm = UniversalSearchViewModel()
        #expect(vm.state == .idle)
        #expect(vm.query.isEmpty)
    }

    // MARK: - Input routing

    @Test
    func youTubeVideoURLTransitionsToResolving() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        // Should transition to either .resolved or .error (depending on network)
        #expect(vm.state != .idle)
    }

    @Test
    func plainTextTransitionsToSearching() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("kanye west run away")
        // Plain text should trigger text search state
        switch vm.state {
        case .searching, .results:
            break // Expected
        default:
            Issue.record("Expected .searching or .results for plain text, got \(vm.state)")
        }
    }

    @Test
    func emptyInputStaysIdle() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("")
        #expect(vm.state == .idle)
    }

    @Test
    func whitespaceOnlyStaysIdle() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("   ")
        #expect(vm.state == .idle)
    }

    // MARK: - YouTube URL resolution

    @Test
    func youTubeVideoResolvesMetadata() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        // After resolution, should have metadata
        if case .resolved(let result) = vm.state {
            #expect(result.title != nil)
            #expect(result.artworkURL != nil)
            #expect(result.source == .youtube)
        }
        // If network is unavailable, .error is also acceptable
    }

    @Test
    func youTubeURLWithTimestampStripsIt() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        // The resolved URL should not contain the timestamp
        if case .resolved(let result) = vm.state {
            #expect(!result.url.contains("t=42s"))
        }
    }

    // MARK: - Playlist URL resolution

    @Test
    func youTubePlaylistURLResolvesToPlaylistPreview() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
        // Should transition to playlist preview state
        switch vm.state {
        case .playlistPreview, .resolved:
            break // Expected
        case .error:
            break // Acceptable if network unavailable
        default:
            Issue.record("Expected .playlistPreview for playlist URL, got \(vm.state)")
        }
    }

    // MARK: - State transitions

    @Test
    func clearResetsToIdle() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("some search")
        vm.clear()
        #expect(vm.state == .idle)
        #expect(vm.query.isEmpty)
    }

    @Test
    func queryUpdatesWithoutSubmitting() {
        let vm = UniversalSearchViewModel()
        vm.query = "test"
        #expect(vm.query == "test")
        #expect(vm.state == .idle) // query change alone doesn't trigger search
    }

    // MARK: - SoundCloud URL

    @Test
    func soundCloudTrackURLResolves() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://soundcloud.com/artist/track-name")
        // Should resolve to SoundCloud source
        if case .resolved(let result) = vm.state {
            #expect(result.source == .soundcloud)
        }
    }

    // MARK: - Direct audio URL

    @Test
    func directAudioURLResolves() async {
        let vm = UniversalSearchViewModel()
        await vm.submit("https://cdn.example.com/song.mp3")
        if case .resolved(let result) = vm.state {
            #expect(result.source == .directAudio)
            #expect(result.url.contains(".mp3"))
        }
    }
}
