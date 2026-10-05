import Foundation
import Testing
@testable import MLM

// MARK: - Structure: the one glass surface (UC-GLASS-05…14, N5–N7)

@Suite("SelectionBarStructureTests")
struct SelectionBarStructureTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private static let barFile = "MLM/Views/TrackList/SelectionBar.swift"

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every Swift source under `MLM/`, relative to the project root.
    private func allSources() throws -> [(path: String, text: String)] {
        let root = projectRoot.appendingPathComponent("MLM")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { url in
            (String(url.path.dropFirst(projectRoot.path.count + 1)), try String(contentsOf: url, encoding: .utf8))
        }
    }

    @Test func theSelectionBarIsTheOnlyCustomGlass() throws {
        let sources = try allSources()
        #expect(sources.count > 100)
        for (path, text) in sources where path != Self.barFile {
            #expect(!text.contains("glassEffect"), "\(path): only the selection bar is custom glass (UC-GLASS-05, N7)")
            #expect(!text.contains("GlassEffectContainer"), "\(path): only the selection bar is custom glass")
        }
        for (path, text) in sources {
            #expect(!text.contains(".buttonStyle(.glass"), "\(path): no glass buttons in B1 (UC-GLASS-08)")
            #expect(!text.contains("glassBackgroundEffect"), "\(path): visionOS only (UC-GLASS-11)")
        }
    }

    @Test func noAvailabilityChecksAnywhere() throws {
        for (path, text) in try allSources() {
            #expect(!text.contains("#available"), "\(path): macOS 27 only — no #available (UC-GLASS-10)")
            #expect(!text.contains("#unavailable"), "\(path): no #unavailable (UC-GLASS-10)")
            #expect(!text.contains("MLMGlass"), "\(path): no glass availability helper")
        }
    }

    @Test func glassIsBuiltExactlyAsUCGlass05() throws {
        let bar = try source(Self.barFile)
        #expect(bar.contains("GlassEffectContainer {"))
        #expect(bar.contains(".glassEffect(.regular.interactive(), in: .capsule)"))
        let code = bar.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(code.filter { $0.contains(".glassEffect(") }.count == 1, "one glass shape: the capsule")
        #expect(bar.contains(".glassEffectID(Self.glassID, in: glassNamespace)"))
        #expect(bar.contains("@Namespace private var glassNamespace"))
        #expect(bar.contains(".buttonStyle(.borderless)"), "borderless inside the capsule (UC-GLASS-08)")
        #expect(!bar.contains(".tint("), "no tint")
        for banned in ["Material", ".shadow(", "NSVisualEffectView", ".blur("] {
            #expect(!bar.contains(banned), "no \(banned) stand-in for glass (UC-GLASS-11)")
        }
    }

    @Test func reduceTransparencyAndReduceMotionAreHonoured() throws {
        let bar = try source(Self.barFile)
        #expect(bar.contains("@Environment(\\.accessibilityReduceTransparency)"))
        #expect(bar.contains(".background(Color(nsColor: .windowBackgroundColor), in: .capsule)"), "UC-GLASS-14")
        #expect(bar.contains(".overlay(Capsule().strokeBorder(.separator))"), "UC-GLASS-14")
        #expect(bar.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(bar.contains(".glassEffectTransition(reduceMotion ? .identity : .materialize)"), "UC-MOTION-03")
        #expect(bar.contains(".transition(.opacity)"))
    }

    @Test func barRegistersNoKeysAndReusesTheSharedBuilders() throws {
        let bar = try source(Self.barFile)
        #expect(!bar.contains(".keyboardShortcut("), "every bar action is a menu item with its key (UC-KEY-36)")
        #expect(bar.contains("TrackMenu("), "More uses the context menu's builder (UC-CM-02)")
        #expect(bar.contains("AddToPlaylistMenuItems("), "Add to Playlist uses CM-SUB-PLAYLIST (UC-CM-11)")
        #expect(bar.contains("showsKeyEquivalents: false"))
        #expect(bar.contains("TrackListActions("), "the table's own actions (UC-SELBAR-03)")
        #expect(bar.contains("actions.playNext(rows)") && bar.contains("actions.download(rows)"))
        #expect(bar.contains(".accessibilityLabel(state.accessibilityLabel)"))
        #expect(bar.contains("AccessibilityNotification.Announcement"))
        #expect(bar.contains("ViewThatFits(in: .horizontal)"), "never wider than the content")
        // The context menu, the Track menu and the bar share one Add to Playlist builder.
        #expect(try source("MLM/Views/TrackList/TrackMenu.swift").contains("AddToPlaylistMenuItems("))
        #expect(try source("MLM/App/Commands/TrackCommands.swift").contains("AddToPlaylistMenuItems("))
    }

    @Test func everyScaffoldedTrackListHostsTheBar() throws {
        let table = try source("MLM/Views/TrackList/TrackListTable.swift")
        #expect(table.contains(".modifier(TrackSelectionBarRegistration(model: model, configuration: configuration, live: live))"))
        /// Lines that are exactly `call` (the slot's content).
        func slots(_ text: String, _ call: String) -> Int {
            text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces) == call }.count
        }
        let content = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(slots(content, "TrackSelectionBar()") == 1, "All Tracks")
        #expect(slots(content, "TrackSelectionBar(host: .searchResults)") == 1, "search results")
        #expect(content.components(separatedBy: ".hostsTrackSelectionBar()").count - 1 == 2)
        let destinations = try source("MLM/Views/Shell/DestinationView.swift")
        #expect(slots(destinations, "TrackSelectionBar()") == 2, "destinations and pushed details")
        #expect(destinations.components(separatedBy: ".hostsTrackSelectionBar()").count - 1 == 2)
    }
}
