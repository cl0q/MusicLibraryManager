import Testing
import Foundation
@testable import MLM

@Suite
struct TransportStructureTests {

    /// Derive the repo root from this file's known path:
    /// .../MLMTests/ViewTests/TransportStructureTests.swift
    private static var repoRoot: URL {
        let thisFile = #filePath
        let url = URL(fileURLWithPath: thisFile)
        // Strip "MLMTests/ViewTests/TransportStructureTests.swift" → 3 components
        return url
            .deletingLastPathComponent() // ViewTests
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - PlayerBar

    @Test
    func playerBar_containsBackButton() throws {
        let src = try readSource("MLM/Views/Player/PlayerBar.swift")
        #expect(src.contains("back_button"))
    }

    @Test
    func playerBar_containsForwardButton() throws {
        let src = try readSource("MLM/Views/Player/PlayerBar.swift")
        #expect(src.contains("forward_button"))
    }

    // MARK: - MLMApp

    /// ⌘← Previous, ⌥⌘← Skip Back 10 Seconds (UC-KEY-07/08); plain ← is not window-wide (W1-2).
    @MainActor
    @Test
    func playbackMenu_containsLeftArrowShortcuts() throws {
        #expect(MenuCommand.previous.shortcut == .cmd(.leftArrow))
        #expect(MenuCommand.skipBack.shortcut == .cmd(.leftArrow, .option))
        let src = try readSource("MLM/App/MLMApp.swift")
        #expect(!src.contains("onKeyPress"), "no window-wide arrow-key seek (DEC-047)")
        #expect(!src.contains("SeekHoldState"))
    }

    /// ⌘→ Next, ⌥⌘→ Skip Forward 10 Seconds (UC-KEY-07/08).
    @MainActor
    @Test
    func playbackMenu_containsRightArrowShortcuts() throws {
        #expect(MenuCommand.next.shortcut == .cmd(.rightArrow))
        #expect(MenuCommand.skipForward.shortcut == .cmd(.rightArrow, .option))
        let src = try readSource("MLM/App/Commands/PlaybackCommands.swift")
        #expect(src.contains("CommandButton(.next, enabled: hasTrack)"))
        #expect(src.contains("CommandButton(.skipForward, enabled: hasTrack)"))
    }

    // MARK: - TrackContextMenu

    @Test
    func trackContextMenu_containsPlayNext() throws {
        let src = try readSource("MLM/Views/Library/TrackContextMenu.swift")
        #expect(src.contains("Play Next"))
    }
}
