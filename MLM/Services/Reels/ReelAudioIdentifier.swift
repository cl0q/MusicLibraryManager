import AVFoundation
import Foundation
import ShazamKit

// MARK: - Identify by Audio (Shazam) (V-REELS.E13, E15)

/// What listening to a reel gave. Offline and no match are different results with different
/// words (V-REELS.E13/E15).
enum ReelAudioResult: Equatable, Sendable {
    case match(ReelShazamMatch)
    /// Shazam answered: nothing recognised (or the video has no audio).
    case noMatch
    /// This Mac is offline.
    case offline
    /// The audio couldn't be read; the cause in plain words.
    case failed(String)
}

protocol ReelAudioIdentifying: Sendable {
    /// Listens to the first `ReelAudioIdentifier.listenSeconds` seconds.
    func identify(_ url: URL) async -> ReelAudioResult
}

enum ReelAudioIdentifier {
    /// The first 12 seconds are enough (V-REELS.E13).
    static let listenSeconds = 12.0

    /// Whether Shazam's error means there was no network.
    static func isOffline(_ error: Error?) -> Bool {
        guard let error else { return false }
        let ns = error as NSError
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
        ]
        if ns.domain == NSURLErrorDomain, offlineCodes.contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOffline(underlying) }
        return false
    }
}

/// ShazamKit over the first 12 seconds of the video's audio.
struct ShazamReelAudioIdentifier: ReelAudioIdentifying {
    func identify(_ url: URL) async -> ReelAudioResult {
        await Task.detached(priority: .userInitiated) { () -> ReelAudioResult in
            let asset = AVURLAsset(url: url)
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return .noMatch }
            guard let reader = try? AVAssetReader(asset: asset) else { return .failed("the audio couldn’t be read") }
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            let provider = reader.outputProvider(for: output)
            do { try reader.start() } catch { return .failed("the audio couldn’t be read") }

            let delegate = ReelShazamDelegate()
            let session = SHSession()
            session.delegate = delegate
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100.0, channels: 1, interleaved: false) else {
                return .failed("the audio couldn’t be read")
            }
            var totalSamples: Int64 = 0
            let maxSamples = Int64(44100.0 * ReelAudioIdentifier.listenSeconds)
            while reader.status == .reading, totalSamples < maxSamples, !Task.isCancelled {
                guard let ready = try? await provider.next() else { break }
                let samples: (buffer: AVAudioPCMBuffer, count: Int)? = ready.withUnsafeSampleBuffer { sampleBuffer in
                    let count = CMSampleBufferGetNumSamples(sampleBuffer)
                    return Self.pcmBuffer(from: sampleBuffer, format: format, numSamples: count).map { ($0, count) }
                }
                if let samples {
                    session.matchStreamingBuffer(samples.buffer, at: AVAudioTime(sampleTime: totalSamples, atRate: 44100.0))
                    totalSamples += Int64(samples.count)
                }
            }
            reader.cancelReading()
            if Task.isCancelled { return .noMatch }
            _ = delegate.wait(timeout: .now() + 4.0)
            if delegate.didMatch, let artist = delegate.matchedArtist, let title = delegate.matchedTitle {
                return .match(ReelShazamMatch(artist: artist, title: title, offset: delegate.matchOffset))
            }
            if ReelAudioIdentifier.isOffline(delegate.error) { return .offline }
            return .noMatch
        }.value
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, numSamples: Int) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(numSamples)
        var length = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &pointer)
        guard status == noErr, let pointer else { return nil }
        pointer.withMemoryRebound(to: Float.self, capacity: numSamples) { source in
            channel.initialize(from: source, count: numSamples)
        }
        return buffer
    }
}

/// ShazamKit's session delegate: waits for the answer.
final class ReelShazamDelegate: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    private(set) var matchedTitle: String?
    private(set) var matchedArtist: String?
    private(set) var matchOffset: TimeInterval?
    private(set) var didMatch = false
    private(set) var error: Error?

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        if let item = match.mediaItems.first {
            matchedTitle = item.title
            matchedArtist = item.artist
            matchOffset = item.matchOffset
            didMatch = true
        }
        semaphore.signal()
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        self.error = error
        semaphore.signal()
    }
}
