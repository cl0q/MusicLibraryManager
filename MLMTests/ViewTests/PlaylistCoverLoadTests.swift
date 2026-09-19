import Testing
import AppKit
import ImageIO
import Foundation
@testable import MLM

@Suite("PlaylistCoverLoadTests", .serialized)
struct PlaylistCoverLoadTests {

    // MARK: - Fixture helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistCoverLoadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    // MARK: - Path-traversal guard

    @Test func safeCoverURL_traversalReducedToLastComponent() {
        let coversDir = URL(fileURLWithPath: "/tmp/covers")
        let url = PlaylistCard.safeCoverURL(coverImagePath: "../../etc/passwd", coversDir: coversDir)
        #expect(url != nil)
        #expect(url!.path.hasPrefix(coversDir.path),
                "Resolved URL must stay inside coversDir, got \(url!.path)")
        #expect(url!.lastPathComponent == "passwd")
    }

    @Test func safeCoverURL_dotDotSlashReduced() {
        let coversDir = URL(fileURLWithPath: "/tmp/covers")
        let url = PlaylistCard.safeCoverURL(coverImagePath: "../secret.png", coversDir: coversDir)
        #expect(url != nil)
        #expect(url!.path.hasPrefix(coversDir.path),
                "Resolved URL must stay inside coversDir, got \(url!.path)")
        #expect(url!.lastPathComponent == "secret.png")
    }

    @Test func safeCoverURL_nilPath_returnsNil() {
        let coversDir = URL(fileURLWithPath: "/tmp/covers")
        let url = PlaylistCard.safeCoverURL(coverImagePath: nil, coversDir: coversDir)
        #expect(url == nil)
    }

    // MARK: - Full pipeline: loadCoverCGImage

    @Test func loadCoverCGImage_realImage_returnsCorrectDimensions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let _ = try writePNG(to: dir, name: "cover.png", width: 120, height: 90)
        let cgImage = PlaylistCard.loadCoverCGImage(coverImagePath: "cover.png", coversDir: dir)

        #expect(cgImage != nil, "loadCoverCGImage must return non-nil for a valid PNG")
        #expect(cgImage?.width == 120)
        #expect(cgImage?.height == 90)
    }

    @Test func loadCoverCGImage_missingFile_returnsNil() {
        let dir = URL(fileURLWithPath: "/tmp/PlaylistCoverLoadTests_nonexistent_\(UUID().uuidString)")
        let cgImage = PlaylistCard.loadCoverCGImage(coverImagePath: "missing.png", coversDir: dir)
        #expect(cgImage == nil, "loadCoverCGImage must return nil for a missing file")
    }

    @Test func loadCoverCGImage_corruptFile_returnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("corrupt.png")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: url)

        let cgImage = PlaylistCard.loadCoverCGImage(coverImagePath: "corrupt.png", coversDir: dir)
        #expect(cgImage == nil, "loadCoverCGImage must return nil for a corrupt/non-image file")
    }

    @Test func loadCoverCGImage_nilPath_returnsNil() {
        let dir = URL(fileURLWithPath: "/tmp/covers")
        let cgImage = PlaylistCard.loadCoverCGImage(coverImagePath: nil, coversDir: dir)
        #expect(cgImage == nil, "loadCoverCGImage must return nil when coverImagePath is nil")
    }

    // MARK: - Callable off the main actor

    @Test func loadCoverCGImage_callableFromDetachedTask() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let _ = try writePNG(to: dir, name: "detached.png", width: 64, height: 48)

        let cgImage: CGImage? = await withTimeout(seconds: 5) {
            await Task.detached(priority: .userInitiated) {
                PlaylistCard.loadCoverCGImage(coverImagePath: "detached.png", coversDir: dir)
            }.value
        }

        #expect(cgImage != nil, "loadCoverCGImage must be callable from a detached (non-main) task")
        #expect(cgImage?.width == 64)
        #expect(cgImage?.height == 48)
    }
}

// MARK: - Test timeout helper

private func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            return await operation()
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}
