import Testing
import AppKit
import ImageIO
import Foundation
@testable import MLM

/// Tests for `TrackCoverView.decodeCGImage` — the `nonisolated static` helper
/// that performs file I/O and image decode off the main actor.
@Suite("TrackCoverDecodeTests", .serialized)
struct TrackCoverDecodeTests {

    // MARK: - Fixture helpers

    /// Write a solid-colour PNG of the given pixel size to `dir` and return its URL.
    private func writePNG(to dir: URL, name: String, width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let data = rep.representation(using: .png, properties: [:])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Write a minimal JPEG file. Uses NSBitmapImageRep JPEG output.
    private func writeJPEG(to dir: URL, name: String, width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackCoverDecodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Decode returns a valid CGImage for real image files

    @Test func decodeJPEG_fullSize_returnsCorrectPixelDimensions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try writeJPEG(to: dir, name: "art_1200.jpg", width: 200, height: 150)
        let cgImage = TrackCoverView.decodeCGImage(at: url)

        #expect(cgImage != nil, "decodeCGImage must return non-nil for a valid JPEG")
        #expect(cgImage?.width == 200)
        #expect(cgImage?.height == 150)
    }

    @Test func decodePNG_fullSize_returnsCorrectPixelDimensions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try writePNG(to: dir, name: "art.png", width: 128, height: 64)
        let cgImage = TrackCoverView.decodeCGImage(at: url)

        #expect(cgImage != nil, "decodeCGImage must return non-nil for a valid PNG")
        #expect(cgImage?.width == 128)
        #expect(cgImage?.height == 64)
    }

    @Test func decode_withMaxPixelSize_downsamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try writeJPEG(to: dir, name: "large.jpg", width: 400, height: 300)
        let cgImage = TrackCoverView.decodeCGImage(at: url, maxPixelSize: 100)

        #expect(cgImage != nil, "decodeCGImage with maxPixelSize must return non-nil")
        // The thumbnail API preserves aspect ratio; the longer side == maxPixelSize.
        let maxDim = max(cgImage?.width ?? 0, cgImage?.height ?? 0)
        #expect(maxDim == 100, "Longer side should equal maxPixelSize (100), got \(maxDim)")
    }

    // MARK: - Nil returns for bad inputs

    @Test func decode_missingFile_returnsNil() {
        let bogus = URL(fileURLWithPath: "/tmp/TrackCoverDecodeTests_nonexistent_\(UUID().uuidString).jpg")
        let cgImage = TrackCoverView.decodeCGImage(at: bogus)
        #expect(cgImage == nil, "decodeCGImage must return nil for a missing file")
    }

    @Test func decode_corruptFile_returnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("corrupt.jpg")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: url)

        let cgImage = TrackCoverView.decodeCGImage(at: url)
        #expect(cgImage == nil, "decodeCGImage must return nil for a corrupt/non-image file")
    }

    // MARK: - Callable off the main actor

    @Test func decode_callableFromDetachedTask() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try writeJPEG(to: dir, name: "detached.jpg", width: 64, height: 48)

        let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
            TrackCoverView.decodeCGImage(at: url)
        }.value

        #expect(cgImage != nil, "decodeCGImage must be callable from a detached (non-main) task")
        #expect(cgImage?.width == 64)
        #expect(cgImage?.height == 48)
    }
}
