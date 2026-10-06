import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Stills of a video (V-REELS.E16, S-REELS-KEYFRAME)

/// One full-size still, handed over while it is read and then dropped.
struct ReelFrame: Sendable {
    let offset: TimeInterval
    let image: ReelImage
}

/// A still kept for the strip and its popover: downsized, with the text found in it.
struct ReelKeyframe: Identifiable, Equatable, Sendable {
    let id = UUID()
    let offset: TimeInterval
    let image: ReelImage
    var texts: [String]

    static func == (lhs: ReelKeyframe, rhs: ReelKeyframe) -> Bool { lhs.id == rhs.id }
}

/// Takes stills across a video, one at a time (never all full-size at once).
protocol KeyframeExtracting: Sendable {
    /// The stills, in order. A frame that can't be read is skipped.
    func frames(of url: URL, count: Int) -> AsyncStream<ReelFrame>
}

enum KeyframeGeometry {
    /// At most this many stills are kept for one reel.
    static let maximumKept = 10
    /// The longer side of a kept still, in pixels.
    static let keptLongSide = 480

    /// Offsets at 5 %, 15 % … 95 % of the duration for ten stills (today's spacing), evenly
    /// spread for any other count.
    static func offsets(duration: TimeInterval, count: Int) -> [TimeInterval] {
        guard duration > 0, count > 0 else { return [] }
        let n = min(count, maximumKept)
        if n == 1 { return [duration * 0.5] }
        return (0..<n).map { duration * (0.05 + 0.9 * (Double($0) / Double(n - 1))) }
    }

    /// The still scaled so its longer side is at most `longSide`.
    static func downsized(_ image: CGImage, longSide: Int = keptLongSide) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longSide else { return image }
        let scale = Double(longSide) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

/// AVFoundation stills, generated off the main actor.
struct AVKeyframeExtractor: KeyframeExtracting {
    func frames(of url: URL, count: Int) -> AsyncStream<ReelFrame> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let asset = AVURLAsset(url: url)
                guard let durationTime = try? await asset.load(.duration) else {
                    continuation.finish()
                    return
                }
                let duration = CMTimeGetSeconds(durationTime)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for offset in KeyframeGeometry.offsets(duration: duration, count: count) {
                    if Task.isCancelled { break }
                    do {
                        let (cgImage, _) = try await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600))
                        continuation.yield(ReelFrame(offset: offset, image: ReelImage(cgImage: cgImage)))
                    } catch {
                        AppLogger.shared.log("Still at \(offset)s failed: \(error.localizedDescription)", level: .warning, source: "Reels")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Reading a video's stills and their text

/// Everything the stills gave.
struct ReelAnalysis: Equatable, Sendable {
    var keyframes: [ReelKeyframe]
    /// Text fragments, longest first.
    var fragments: [String]
    /// `Artist – Title` shaped lines with the still they appeared in.
    var candidates: [ReelTextCandidate]
}

protocol ReelAnalyzing: Sendable {
    func analyze(_ url: URL) async -> ReelAnalysis
}

/// Stills, then the text of each one. At most ten downsized stills stay in memory; the full-size
/// frame is released as soon as its text is read.
struct LiveReelAnalyzer: ReelAnalyzing {
    var extractor: any KeyframeExtracting = AVKeyframeExtractor()
    var reader: any ReelTextReading = VisionReelTextReader()

    func analyze(_ url: URL) async -> ReelAnalysis {
        var keyframes: [ReelKeyframe] = []
        var perFrame: [[String]] = []
        var candidates: [ReelTextCandidate] = []
        var seen = Set<String>()
        for await frame in extractor.frames(of: url, count: KeyframeGeometry.maximumKept) {
            if Task.isCancelled { break }
            let texts = (await reader.read(frame.image)).map(ReelTextParsing.clean).filter {
                $0.count > 1 && !ReelTextParsing.isInterfaceNoise($0)
            }
            perFrame.append(texts)
            for var candidate in ReelTextParsing.candidates(in: texts) where seen.insert(candidate.id).inserted {
                candidate.stillOffset = frame.offset
                candidates.append(candidate)
            }
            let thumbnail = ReelImage(cgImage: KeyframeGeometry.downsized(frame.image.cgImage))
            keyframes.append(ReelKeyframe(offset: frame.offset, image: thumbnail, texts: Array(NSOrderedSet(array: texts)) as? [String] ?? texts))
        }
        // Best candidates first across all stills (the same order as one list).
        let ordered = candidates.sorted {
            $0.score != $1.score ? $0.score > $1.score : ($0.artist.count + $0.title.count) > ($1.artist.count + $1.title.count)
        }
        return ReelAnalysis(keyframes: keyframes, fragments: ReelTextParsing.fragments(from: perFrame), candidates: ordered)
    }
}
