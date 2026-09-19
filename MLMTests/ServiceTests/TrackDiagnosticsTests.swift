import Foundation
import Testing
@testable import MLM

/// Tests for the pure `parseDecodeOutput` parser in `TrackDiagnosticsService`.
///
/// No ffmpeg execution — these validate the stderr classification rules
/// (error vs warning, broken-frame regex, cap at 250, blank-line trimming).
struct TrackDiagnosticsTests {

    // MARK: - Mixed input

    /// Mixed stderr with errors, warnings, and broken-frame lines.
    ///
    /// Expected classification:
    /// - "incomplete frame" → error + broken frame
    /// - "Warning: skipping junk" → warning
    /// - "Error while decoding stream" → error + broken frame
    /// - "corrupt input packet" → error + broken frame
    @Test
    func parsesMixedDecodeOutput() {
        let stderr = """
        [mp3float @ 0x1] incomplete frame
        [mp3 @ 0x2] Warning: skipping junk
        [aac @ 0x3] Error while decoding stream
        [flac @ 0x4] corrupt input packet
        """

        let summary = TrackDiagnosticsService.parseDecodeOutput(stderr)

        #expect(summary.errorLines.count == 3)
        #expect(summary.warningLines.count == 1)
        #expect(summary.brokenFrameCount == 3)
    }

    // MARK: - Cap at 250

    /// When stderr contains more than 250 error lines, the parser caps at 250.
    @Test
    func capsErrorLinesAt250() {
        let lines = (0..<300).map { "[codec @ 0x\($0)] decode error on frame \($0)" }
        let stderr = lines.joined(separator: "\n")

        let summary = TrackDiagnosticsService.parseDecodeOutput(stderr)

        #expect(summary.errorLines.count == 250)
    }

    // MARK: - Empty input

    /// Empty stderr produces zero counts and empty arrays.
    @Test
    func emptyInputProducesZeros() {
        let summary = TrackDiagnosticsService.parseDecodeOutput("")

        #expect(summary.errorLines.isEmpty)
        #expect(summary.warningLines.isEmpty)
        #expect(summary.brokenFrameCount == 0)
    }

    // MARK: - Blank-line and whitespace trimming

    /// Blank lines are dropped; leading/trailing whitespace is trimmed.
    @Test
    func trimsAndDropsBlankLines() {
        let stderr = """

           [mp3 @ 0x1] some error
        \t
           [mp3 @ 0x2] Warning: minor issue

        """

        let summary = TrackDiagnosticsService.parseDecodeOutput(stderr)

        #expect(summary.errorLines.count == 1)
        #expect(summary.warningLines.count == 1)
        #expect(summary.errorLines.first == "[mp3 @ 0x1] some error")
        #expect(summary.warningLines.first == "[mp3 @ 0x2] Warning: minor issue")
    }
}
