import Testing
import Foundation

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

    @Test
    func mlmApp_containsLeftArrowShortcut() throws {
        let src = try readSource("MLM/App/MLMApp.swift")
        #expect(src.contains(".leftArrow"))
    }

    @Test
    func mlmApp_containsRightArrowShortcut() throws {
        let src = try readSource("MLM/App/MLMApp.swift")
        #expect(src.contains(".rightArrow"))
    }

    // MARK: - TrackContextMenu

    @Test
    func trackContextMenu_containsPlayNext() throws {
        let src = try readSource("MLM/Views/Library/TrackContextMenu.swift")
        #expect(src.contains("Play Next"))
    }
}
