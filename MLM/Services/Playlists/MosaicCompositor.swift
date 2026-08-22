import AppKit
import Foundation

/// Stateless PNG-compositing utility for playlist cover images.
/// All operations produce a 512×512 PNG ready to write to the cover cache.
///
/// Three entry points:
/// - `composeMosaicPNG`  — 2×2 mosaic (D-01 auto4); nil tiles become gradient gaps (D-02).
/// - `composeSingleCoverPNG` — single 512×512 image (D-01 auto1).
/// - `composeFallbackPNG` — deterministic gradient + initials (D-03).
///
/// Phase 36 Plan 02 — consumed by `PlaylistCoverService`.
enum MosaicCompositor {

    enum CompositingError: Error {
        case bitmapAllocationFailed
        case pngEncodingFailed
    }

    // MARK: - Public API

    /// 2×2 mosaic. `tiles` MUST have exactly 4 entries (nil → gradient gap).
    /// `gradients` MUST have exactly 4 entries (one per slot, used when the tile is nil).
    static func composeMosaicPNG(
        tiles: [NSImage?],
        gradients: [(NSColor, NSColor)],
        outputURL: URL
    ) throws {
        precondition(tiles.count == 4 && gradients.count == 4)
        let rep = try makeBitmapRep()
        try render(into: rep) { _ in
            // Slot positions: top-left, top-right, bottom-left, bottom-right
            let positions: [NSPoint] = [
                NSPoint(x: 0,   y: 256),
                NSPoint(x: 256, y: 256),
                NSPoint(x: 0,   y: 0),
                NSPoint(x: 256, y: 0),
            ]
            let tileSize = NSSize(width: 256, height: 256)
            for idx in 0..<4 {
                let rect = NSRect(origin: positions[idx], size: tileSize)
                if let image = tiles[idx] {
                    drawCenterCropped(image, in: rect)
                } else {
                    drawGradient(from: gradients[idx].0, to: gradients[idx].1, in: rect)
                }
            }
            // 2-pixel seam between tiles (UI-SPEC line 57)
            let seamColor = NSColor.windowBackgroundColor
            seamColor.setFill()
            NSRect(x: 0, y: 255, width: 512, height: 2).fill()  // horizontal seam
            NSRect(x: 255, y: 0, width: 2, height: 512).fill()  // vertical seam
        }
        try writePNG(rep: rep, to: outputURL)
    }

    /// Single cover (auto1 — D-01 when track count < 4). Center-crops to 512×512.
    static func composeSingleCoverPNG(image: NSImage, outputURL: URL) throws {
        let rep = try makeBitmapRep()
        try render(into: rep) { _ in
            drawCenterCropped(image, in: NSRect(x: 0, y: 0, width: 512, height: 512))
        }
        try writePNG(rep: rep, to: outputURL)
    }

    /// Fallback (D-03): gradient + uppercase initials.
    static func composeFallbackPNG(
        playlistId: Int64,
        name: String,
        outputURL: URL
    ) throws {
        let rep = try makeBitmapRep()
        let (start, end) = GradientPalette.colors(forPlaylistId: playlistId)
        let initials = GradientPalette.initials(for: name)

        try render(into: rep) { _ in
            drawGradient(from: start, to: end, in: NSRect(x: 0, y: 0, width: 512, height: 512))

            // Initials (UI-SPEC line 81): system bold, white 95% alpha.
            // 192pt at the 512px raster gives ~96pt logical at the typical @2x card.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 192, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95)
            ]
            let attrString = NSAttributedString(string: initials, attributes: attrs)
            let size = attrString.size()
            let origin = NSPoint(
                x: (512 - size.width) / 2,
                y: (512 - size.height) / 2
            )
            attrString.draw(at: origin)
        }
        try writePNG(rep: rep, to: outputURL)
    }

    // MARK: - Private helpers

    private static func makeBitmapRep() throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 512, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else { throw CompositingError.bitmapAllocationFailed }
        rep.size = NSSize(width: 512, height: 512)
        return rep
    }

    private static func render(
        into rep: NSBitmapImageRep,
        block: (NSGraphicsContext) -> Void
    ) throws {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CompositingError.bitmapAllocationFailed
        }
        NSGraphicsContext.current = ctx
        block(ctx)
    }

    private static func writePNG(rep: NSBitmapImageRep, to url: URL) throws {
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CompositingError.pngEncodingFailed
        }
        try pngData.write(to: url, options: .atomic)
    }

    private static func drawCenterCropped(_ image: NSImage, in rect: NSRect) {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return }
        let srcAspect = srcSize.width / srcSize.height
        let dstAspect = rect.size.width / rect.size.height

        var srcRect: NSRect
        if srcAspect > dstAspect {
            // Source wider — crop horizontally
            let newWidth = srcSize.height * dstAspect
            srcRect = NSRect(
                x: (srcSize.width - newWidth) / 2, y: 0,
                width: newWidth, height: srcSize.height
            )
        } else {
            // Source taller — crop vertically
            let newHeight = srcSize.width / dstAspect
            srcRect = NSRect(
                x: 0, y: (srcSize.height - newHeight) / 2,
                width: srcSize.width, height: newHeight
            )
        }
        image.draw(in: rect, from: srcRect, operation: .copy, fraction: 1.0)
    }

    private static func drawGradient(from start: NSColor, to end: NSColor, in rect: NSRect) {
        let gradient = NSGradient(starting: start, ending: end)
        // topLeading → bottomTrailing per UI-SPEC line 142
        gradient?.draw(in: rect, angle: -45)
    }
}
