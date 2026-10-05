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
    /// PP-MAIN-01 (fixed in W2-C): Next onto a track whose file is gone no longer stalls on it
    /// and no longer blames "the file" in raw words. The missing file is recorded, the track is
    /// skipped, history isn't touched, and with nothing playable left the player stops and
    /// names the track and the reason.
    @Test func missingTrackIsSkippedRecordedAndNamed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playablePath = directory.appendingPathComponent("a.mp3").path
        FileManager.default.createFile(atPath: playablePath, contents: Data())

        func track(_ id: Int64, _ title: String, _ path: String) -> Track {
            var track = Track(artist: "Artist", album: "Album", title: title, format: "mp3", originalPath: path)
            track.id = id
            track.organizedPath = path
            return track
        }

        let env = PlaybackTestEnvironment()
        let viewModel = PlaybackViewModel(audioPlayer: RejectionAudioPlayer(), environment: env.environment)
        let a = track(1, "A", playablePath)
        let b = track(2, "B", directory.appendingPathComponent("missing.mp3").path)

        await viewModel.playTrack(a, queue: [a, b])
        await viewModel.next()

        #expect(viewModel.currentTrack == nil)
        #expect(viewModel.cantPlay == CantPlayState(track: b, reason: .fileMissing))
        #expect(viewModel.history == [a])
        #expect(viewModel.upcoming.isEmpty, "the missing track is consumed, never retried")
        #expect(env.recordedMissing == [2])
        #expect(viewModel.notice?.text == "Skipped “B” — file missing")
        #expect(!(viewModel.notice?.text.contains("Playback unavailable") ?? true))
    }
}
