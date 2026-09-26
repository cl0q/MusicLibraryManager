import Foundation
import Testing
@testable import MLM

@MainActor
private final class RejectionAudioPlayer: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 60
    var currentPosition: TimeInterval = 0

    func loadFile(at url: URL) throws { state = .stopped }
    func play() throws { state = .playing }
    func pause() { state = .paused }
    func togglePlayPause() throws { try play() }
    func stop() { state = .stopped }
    func seek(to position: TimeInterval) throws { currentPosition = position }
    func setVolume(_ volume: Float) {}
    func applyLUFSCompensation(lufsI: Double?) {}
}

@Suite
@MainActor
struct PlaybackRejectionTests {
    @Test func missingAttemptRetainsCurrentTrackAndDoesNotCommitHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playablePath = directory.appendingPathComponent("a.mp3").path
        FileManager.default.createFile(atPath: playablePath, contents: Data())

        func track(_ id: Int64, _ title: String, _ path: String) -> Track {
            var track = Track(artist: "Artist", album: "Album", title: title, format: "mp3", originalPath: path)
            track.id = id
            return track
        }

        let player = RejectionAudioPlayer()
        let viewModel = PlaybackViewModel(audioPlayer: player)
        let a = track(1, "A", playablePath)
        let b = track(2, "B", directory.appendingPathComponent("missing.mp3").path)

        await viewModel.playTrack(a, queue: [a, b])
        await viewModel.next()

        #expect(viewModel.currentTrack == a)
        #expect(viewModel.history == [a])
        #expect(viewModel.upcoming == [b])
        #expect(viewModel.errorMessage?.contains("B") == true)
    }
}
