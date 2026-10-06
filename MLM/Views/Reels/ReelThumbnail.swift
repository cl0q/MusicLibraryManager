import AppKit
import AVFoundation
import SwiftUI

/// A small still of a reel's video for the list row. Made off the main actor, kept in memory.
struct ReelThumbnail: View {
    let url: URL

    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            image = nil
            let made = await Self.makeStill(of: url)
            if let made { Self.cache.setObject(made, forKey: url as NSURL) }
            image = made
        }
    }

    private static func makeStill(of url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 136, height: 176)
            guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        }.value
    }
}
