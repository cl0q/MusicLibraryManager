import AppKit
import XCTest

@testable import MLM

/// Tests for the now-playing artwork scaling helper used by
/// `RemoteCommandService` to produce `MPMediaItemArtwork` images.
final class NowPlayingArtworkTests: XCTestCase {

    // MARK: - Helpers

    /// Create a solid-color NSImage of the given pixel size.
    private func makeImage(width: CGFloat, height: CGFloat, color: NSColor = .systemBlue) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.drawSwatch(in: NSRect(x: 0, y: 0, width: width, height: height))
        image.unlockFocus()
        return image
    }

    // MARK: - Scale-to-size tests

    func testScaleSquareToSquareReturnsRequestedSize() {
        let source = makeImage(width: 500, height: 500)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 128, height: 128))
        XCTAssertEqual(result.size.width, 128, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 128, accuracy: 0.01)
    }

    func testScaleLandscapeToSquareReturnsRequestedSize() {
        let source = makeImage(width: 800, height: 400)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(result.size.width, 200, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 200, accuracy: 0.01)
    }

    func testScalePortraitToSquareReturnsRequestedSize() {
        let source = makeImage(width: 300, height: 600)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 150, height: 150))
        XCTAssertEqual(result.size.width, 150, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 150, accuracy: 0.01)
    }

    func testScaleToNonSquareReturnsRequestedSize() {
        let source = makeImage(width: 500, height: 500)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 300, height: 100))
        XCTAssertEqual(result.size.width, 300, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 100, accuracy: 0.01)
    }

    func testScaleWithZeroSizeReturnsSource() {
        let source = makeImage(width: 500, height: 500)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 0, height: 0))
        // Should return the original source unchanged.
        XCTAssertEqual(result.size.width, 500, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 500, accuracy: 0.01)
    }

    func testScaleIdentityReturnsSameSize() {
        let source = makeImage(width: 256, height: 256)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 256, height: 256))
        XCTAssertEqual(result.size.width, 256, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 256, accuracy: 0.01)
    }

    func testScaleUpscaleReturnsRequestedSize() {
        let source = makeImage(width: 100, height: 100)
        let result = RemoteCommandService.scaleImage(source, toSize: CGSize(width: 600, height: 600))
        XCTAssertEqual(result.size.width, 600, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 600, accuracy: 0.01)
    }
}
