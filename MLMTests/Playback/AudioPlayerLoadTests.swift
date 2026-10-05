import AVFoundation
import Foundation
import Testing
@testable import MLM

/// W2-C review: a file that can't be opened never unloads the playing one (S8), and a pause or
/// seek can't be mistaken for the natural end of the file (the completion handler that
/// `AVAudioPlayerNode.stop()` fires). Nothing is played: no sound reaches the output device.
@Suite("AudioPlayerLoadTests")
struct AudioPlayerLoadTests {

    private func writeSilentWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-silent-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 8_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    @Test func aFileThatCantBeOpenedLeavesTheLoadedOneAlone() throws {
        let good = try writeSilentWAV(seconds: 2)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-bad-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: bad)
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }
        let player = AudioPlayer()
        try player.loadFile(at: good)
        #expect(abs(player.duration - 2) < 0.01)
        #expect(throws: (any Error).self) { try player.loadFile(at: bad) }
        #expect(abs(player.duration - 2) < 0.01, "the good file is still loaded")
        #expect(throws: (any Error).self) { try player.loadFile(at: URL(fileURLWithPath: "/nonexistent/x.m4a")) }
        #expect(abs(player.duration - 2) < 0.01)
    }

    @Test func onlyTheCompletionOfTheLastScheduleIsTheEndOfTheFile() throws {
        let generation = 7
        #expect(AudioPlayer.completionIsNaturalEnd(callbackGeneration: generation, currentGeneration: generation))
        #expect(!AudioPlayer.completionIsNaturalEnd(callbackGeneration: generation,
                                                    currentGeneration: AudioPlayer.nextGeneration(after: generation)),
                "a pause or seek takes a new generation, so its stop-completion is ignored")
        // `pause()` and `seek(to:)` take the new generation before they stop the node.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MLM/Services/Audio/AudioPlayer.swift"), encoding: .utf8)
        let pause = try #require(source.range(of: "func pause() {"))
        let pauseBody = String(source[pause.upperBound...].prefix(900))
        let bump = try #require(pauseBody.range(of: "scheduleGeneration = Self.nextGeneration(after: scheduleGeneration)"))
        let stop = try #require(pauseBody.range(of: "playerNode.stop()"))
        #expect(bump.lowerBound < stop.lowerBound)
        let seek = try #require(source.range(of: "func seek(to position: TimeInterval) throws {"))
        let seekBody = String(source[seek.upperBound...].prefix(700))
        #expect(seekBody.contains("scheduleGeneration = Self.nextGeneration(after: scheduleGeneration)\n        playerNode.stop()"))
    }
}
