import Foundation
import AVFoundation

/// Audio preprocessing helper that extracts raw Float32 PCM audio samples at 16,000 Hz mono
/// using native AVFoundation APIs, customized for input into CoreML models like YAMNet.
final class AudioPreprocessor: Sendable {
    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    /// Whether the preprocessor is available. Natively always available on macOS.
    var isAvailable: Bool { true }

    /// Resample a specific time range of an audio file to 16,000 Hz mono 32-bit float PCM.
    ///
    /// - Parameters:
    ///   - path: The absolute path of the audio file.
    ///   - startOffset: The start time in seconds (optional).
    ///   - duration: The duration in seconds to extract (optional).
    /// - Returns: An array of Float32 samples, or nil if extraction failed.
    func resampleTo16kHzMono(
        at path: String,
        startOffset: Double? = nil,
        duration: Double? = nil
    ) async throws -> [Float]? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        
        guard let track = try await asset.load(.tracks).first(where: { $0.mediaType == .audio }) else {
            return nil
        }
        
        let reader = try AVAssetReader(asset: asset)
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        
        if let start = startOffset {
            let startTime = CMTime(seconds: start, preferredTimescale: 600)
            if let dur = duration {
                let durationTime = CMTime(seconds: dur, preferredTimescale: 600)
                reader.timeRange = CMTimeRange(start: startTime, duration: durationTime)
            } else {
                reader.timeRange = CMTimeRange(start: startTime, end: .positiveInfinity)
            }
        } else if let dur = duration {
            let durationTime = CMTime(seconds: dur, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: .zero, duration: durationTime)
        }
        
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AVAssetReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }
        
        var samples: [Float] = []
        
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }
            
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { (bufferPointer: UnsafeMutableRawBufferPointer) in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
            }
            
            let sampleCount = length / 4
            data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
                guard let floatPtr = rawBuffer.baseAddress?.bindMemory(to: Float.self, capacity: sampleCount) else { return }
                for i in 0..<sampleCount {
                    samples.append(floatPtr[i])
                }
            }
        }
        
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "AVAssetReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reading failed"])
        }
        
        return samples
    }

    /// Segment a raw Float sample array into non-overlapping windows of a specific size.
    /// Used to chunk audio for sequential model predictions (e.g. YAMNet windows of 15,600 samples).
    ///
    /// - Parameters:
    ///   - samples: Raw Float array.
    ///   - windowSize: Number of samples per window (e.g. 15,600).
    /// - Returns: Array of sample slices.
    static func segment(samples: [Float], windowSize: Int) -> [ArraySlice<Float>] {
        guard windowSize > 0, samples.count >= windowSize else { return [] }
        
        let windowCount = samples.count / windowSize
        var segmented: [ArraySlice<Float>] = []
        segmented.reserveCapacity(windowCount)
        
        for w in 0..<windowCount {
            let start = w * windowSize
            let slice = samples[start..<(start + windowSize)]
            segmented.append(slice)
        }
        
        return segmented
    }
}
