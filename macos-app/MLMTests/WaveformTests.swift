import Foundation
import Testing
@testable import MLM

/// Unit tests for WaveformHelpers — pure functions, no AppKit/SwiftUI required.
struct WaveformTests {

    // MARK: - adaptiveBinCount

    @Test func adaptiveBinCountShortTrack() {
        // 90 s: 2 * 90 = 180 < 200 minimum → expect floor
        #expect(WaveformHelpers.adaptiveBinCount(duration: 90) == 200)
    }

    @Test func adaptiveBinCountTwoHourTrack() {
        // 7200 s: 2 * 7200 = 14400 == cap → expect cap
        #expect(WaveformHelpers.adaptiveBinCount(duration: 7200) == 14_400)
    }

    @Test func adaptiveBinCountExceedsCap() {
        // 8000 s: 2 * 8000 = 16000 > cap → expect clamped to 14400
        #expect(WaveformHelpers.adaptiveBinCount(duration: 8_000) == 14_400)
    }

    @Test func adaptiveBinCountTypicalTrack() {
        // 300 s (5 min): 2 * 300 = 600, above floor, below cap → expect 600
        #expect(WaveformHelpers.adaptiveBinCount(duration: 300) == 600)
    }

    // MARK: - amplitudeColor

    @Test func amplitudeColorQuietDoesNotCrash() {
        // peak = 0.0 → steel-blue range; function must not crash
        let color = WaveformHelpers.amplitudeColor(for: 0.0, played: true)
        _ = color  // compile + runtime check
        #expect(Bool(true))
    }

    @Test func amplitudeColorLoudDoesNotCrash() {
        // peak = 1.0 → orange-red range; function must not crash
        let color = WaveformHelpers.amplitudeColor(for: 1.0, played: false)
        _ = color
        #expect(Bool(true))
    }

    // MARK: - seekFraction

    @Test func seekFractionNoScroll() {
        // tapX=300, offset=0, width=600 → 300/600 = 0.5
        let f = WaveformHelpers.seekFraction(tapX: 300, scrollOffset: 0, totalContentWidth: 600)
        #expect(abs(f - 0.5) < 0.001)
    }

    @Test func seekFractionWithScroll() {
        // tapX=0, offset=300, width=600 → (0+300)/600 = 0.5
        let f = WaveformHelpers.seekFraction(tapX: 0, scrollOffset: 300, totalContentWidth: 600)
        #expect(abs(f - 0.5) < 0.001)
    }

    @Test func seekFractionClampsToZero() {
        // Negative absoluteX → clamp to 0
        let f = WaveformHelpers.seekFraction(tapX: -50, scrollOffset: 0, totalContentWidth: 600)
        #expect(f == 0.0)
    }

    @Test func seekFractionClampsToOne() {
        // tapX beyond width → clamp to 1
        let f = WaveformHelpers.seekFraction(tapX: 700, scrollOffset: 0, totalContentWidth: 600)
        #expect(f == 1.0)
    }

    @Test func seekFractionZeroWidth() {
        // Guard against division by zero → return 0
        let f = WaveformHelpers.seekFraction(tapX: 100, scrollOffset: 0, totalContentWidth: 0)
        #expect(f == 0.0)
    }
}
