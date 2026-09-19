import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MLM

@Suite("ArtworkService (saveResized)")
struct ArtworkServiceTests {

    /// Generates an in-memory JPEG of the given pixel dimensions.
    private func makeJPEGData(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill with a solid color so the image is valid
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Reads the pixel dimensions of a JPEG file at the given URL.
    private func pixelDimensions(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    @Test func saveResizedWritesSmallFileWithMaxDimension256() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = ArtworkService(cacheDir: tempDir)

        // Create a 1200x1200 JPEG (simulating a full-resolution artwork)
        guard let largeData = makeJPEGData(width: 1200, height: 1200) else {
            Issue.record("Failed to generate test JPEG data")
            return
        }

        try service.saveResized(data: largeData, trackId: 42)

        // Verify large file exists and is roughly the original size
        let largePath = service.cachedPath(trackId: 42, size: .large)
        #expect(FileManager.default.fileExists(atPath: largePath.path))

        // Verify small file exists and has max dimension <= 256
        let smallPath = service.cachedPath(trackId: 42, size: .small)
        #expect(FileManager.default.fileExists(atPath: smallPath.path))

        if let dims = pixelDimensions(of: smallPath) {
            #expect(dims.width <= 256, "Small width \(dims.width) should be <= 256")
            #expect(dims.height <= 256, "Small height \(dims.height) should be <= 256")
        } else {
            Issue.record("Could not read pixel dimensions of small file")
        }

        // Verify the small file is smaller in bytes than the large file
        let largeSize = try FileManager.default.attributesOfItem(atPath: largePath.path)[.size] as? Int ?? 0
        let smallSize = try FileManager.default.attributesOfItem(atPath: smallPath.path)[.size] as? Int ?? 0
        #expect(smallSize < largeSize, "Small file (\(smallSize) bytes) should be smaller than large (\(largeSize) bytes)")
    }

    @Test func saveResizedPreservesLargeFileAtOriginalSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = ArtworkService(cacheDir: tempDir)

        guard let data = makeJPEGData(width: 800, height: 600) else {
            Issue.record("Failed to generate test JPEG data")
            return
        }

        try service.saveResized(data: data, trackId: 99)

        let largePath = service.cachedPath(trackId: 99, size: .large)
        if let dims = pixelDimensions(of: largePath) {
            #expect(dims.width == 800, "Large width should be preserved at 800")
            #expect(dims.height == 600, "Large height should be preserved at 600")
        } else {
            Issue.record("Could not read pixel dimensions of large file")
        }
    }

    @Test func downscaleJPEGReturnsNilForInvalidData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let result = ArtworkService.downscaleJPEG(data: garbage, maxPixelSize: 256)
        #expect(result == nil, "Invalid data should return nil")
    }
}
