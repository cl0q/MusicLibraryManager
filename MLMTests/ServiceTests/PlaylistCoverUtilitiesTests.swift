import Testing
import AppKit
@testable import MLM

/// Tests for the three pure utility files that PlaylistCoverService composes:
/// - GradientPalette (deterministic palette + initials)
/// - MosaicCompositor (PNG composition for fallback / single / 2×2 mosaic)
/// - ArtworkExtractor (silent-nil contract for unreadable URLs)
///
/// Phase 36 Plan 02, Task 1 RED.
@MainActor
@Suite("Playlist cover utilities (Phase 36)")
struct PlaylistCoverUtilitiesTests {

    // MARK: - GradientPalette

    @Test func gradientPalette_id0_returnsIndex0Pair() {
        let (start, end) = GradientPalette.colors(forPlaylistId: 0)
        // index 0: accent + blended dark
        #expect(start == NSColor.controlAccentColor)
        #expect(end != start, "Blended dark should differ from the source accent")
    }

    @Test func gradientPalette_id4_wrapsToIndex0() {
        let (a0, b0) = GradientPalette.colors(forPlaylistId: 0)
        let (a4, b4) = GradientPalette.colors(forPlaylistId: 4)
        #expect(a0 == a4 && b0 == b4, "id 4 must wrap to the same palette pair as id 0")
    }

    @Test func gradientPalette_id1_isBlueIndigoPair() {
        let (start, end) = GradientPalette.colors(forPlaylistId: 1)
        #expect(start == NSColor.systemBlue)
        #expect(end == NSColor.systemIndigo)
    }

    @Test func gradientPalette_negativeId_handlesGracefully() {
        // abs() must guard against negative ids
        let (start, end) = GradientPalette.colors(forPlaylistId: -3)
        // abs(-3) % 4 == 3 → systemGray + controlAccentColor
        #expect(start == NSColor.systemGray)
        #expect(end == NSColor.controlAccentColor)
    }

    @Test func gradientPalette_initials_twoWordEmojiName() {
        let result = GradientPalette.initials(for: "🎵 Workout")
        #expect(result == "🎵W", "Two-word name takes first cluster of each word, uppercased")
    }

    @Test func gradientPalette_initials_singleNonLatinWord() {
        let result = GradientPalette.initials(for: "やる気")
        #expect(result == "やる", "Single word: first 2 grapheme clusters")
    }

    @Test func gradientPalette_initials_singleChar_noPadding() {
        let result = GradientPalette.initials(for: "X")
        #expect(result == "X", "Single char must not be padded")
    }

    @Test func gradientPalette_initials_trimsWhitespace() {
        let result = GradientPalette.initials(for: "  Hello World  ")
        #expect(result == "HW")
    }

    // MARK: - MosaicCompositor

    @Test func mosaicCompositor_composeFallback_writes512PNG() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_cover_fallback_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try MosaicCompositor.composeFallbackPNG(
            playlistId: 7, name: "Test Playlist", outputURL: tmpURL
        )

        #expect(FileManager.default.fileExists(atPath: tmpURL.path),
                "composeFallbackPNG must write the output file")

        let img = NSImage(contentsOf: tmpURL)
        #expect(img != nil, "Output must be a decodable PNG")
        #expect(img?.size == NSSize(width: 512, height: 512),
                "Output must be 512×512")
    }

    @Test func mosaicCompositor_composeMosaic_with4GradientGaps_writes512PNG() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_cover_mosaic_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let palette = GradientPalette.colors(forPlaylistId: 2)
        let gradients = Array(repeating: palette, count: 4)
        let tiles: [NSImage?] = [nil, nil, nil, nil]

        try MosaicCompositor.composeMosaicPNG(
            tiles: tiles, gradients: gradients, outputURL: tmpURL
        )

        let img = NSImage(contentsOf: tmpURL)
        #expect(img?.size == NSSize(width: 512, height: 512))
    }

    @Test func mosaicCompositor_composeSingle_writes512PNG() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_cover_single_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Source: a 256×256 solid-color image
        let source = NSImage(size: NSSize(width: 256, height: 256))
        source.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 256, height: 256).fill()
        source.unlockFocus()

        try MosaicCompositor.composeSingleCoverPNG(image: source, outputURL: tmpURL)

        let img = NSImage(contentsOf: tmpURL)
        #expect(img?.size == NSSize(width: 512, height: 512),
                "composeSingleCoverPNG must upsample source to 512×512")
    }

    // MARK: - ArtworkExtractor

    @Test func artworkExtractor_unreadableURL_returnsNil() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/__mlm_does_not_exist_\(UUID().uuidString).mp3")
        let result = await ArtworkExtractor.extract(audioURL: bogusURL)
        #expect(result == nil, "Unreadable URL must silently return nil (not throw)")
    }
}
