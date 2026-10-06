import Testing
import Foundation
@testable import MLM

/// W1-2 Settings scene (W-SETTINGS, UC-WIN-03/04/05, DEC-035): eight tabs in order, the tab
/// router with deep links, no AppKit settings window, and every "Open Settings" call site
/// landing on the tab that fixes its problem (PP-SHELL-33).
@Suite("Settings scene and deep links (W1-2)")
@MainActor
struct SettingsSceneTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SettingsSceneTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Tabs

    @Test func eightTabsInTheDesignedOrder() {
        #expect(SettingsTab.allCases.map(\.title) == [
            "General", "Library", "Playback", "Sources", "Backup", "Storage Location", "Maintenance", "Advanced",
        ])
    }

    @Test func oldTabTagsStillResolve() {
        for tag in ["library", "sources", "maintenance", "backup", "storage", "playback", "advanced"] {
            #expect(SettingsTab(rawValue: tag) != nil, "remembered tab \(tag) must survive")
        }
    }

    @Test func libraryTabsAreDimmedWithoutALibrary() {
        #expect(SettingsTab.allCases.filter { !$0.belongsToLibrary } == [.general, .playback, .sources])
    }

    @Test func hostViewHostsEveryTabInOrder() throws {
        let src = try source("MLM/Views/Settings/SettingsView.swift")
        var cursor = src.startIndex
        for tab in SettingsTab.allCases {
            let range = try #require(src.range(of: "pane(.\(tab.rawValue))", range: cursor..<src.endIndex),
                                     "tab \(tab) missing or out of order")
            cursor = range.upperBound
        }
        for pane in ["GeneralSettingsView()", "LibrarySetupView()", "PlaybackSettingsView()", "SourcesSetupView()",
                     "BackupSettingsView()", "DataLocationsView()", "MaintenanceView()", "GrooveStudioView()"] {
            #expect(src.contains(pane), "existing pane \(pane) must stay reachable")
        }
        #expect(src.contains("TabView(selection: $router.selectedTab)"))
        #expect(src.contains(".tabItem {") && src.contains("Label(tab.title, systemImage: tab.systemImage)"))
        #expect(src.contains("No library is open. Settings that belong to a library are dimmed until you open one."))
        #expect(src.contains("Button(\"Choose Library…\")"))
        #expect(!src.contains("Genre Workshop"), "retired word (UC-GLOSS-02)")
    }

    @Test func generalTabHasNoSpaceBarChoice() throws {
        let src = try source("MLM/Views/Settings/GeneralSettingsView.swift")
        #expect(src.contains("Toggle(\"Open the last library at launch\""))
        #expect(!src.localizedCaseInsensitiveContains("space bar"), "§10 Q1: no Space-bar setting")
    }

    // MARK: Router

    @Test func routerRemembersTheSelectedTab() {
        let defaults = makeDefaults()
        let router = SettingsRouter(defaults: defaults)
        #expect(router.selectedTab == .general)
        router.select(.backup)
        #expect(defaults.string(forKey: SettingsRouter.selectedTabKey) == "backup")
        #expect(SettingsRouter(defaults: defaults).selectedTab == .backup)
    }

    @Test func routerReadsTheOldPersistedKey() {
        let defaults = makeDefaults()
        defaults.set("maintenance", forKey: "settings.selectedTab")
        #expect(SettingsRouter(defaults: defaults).selectedTab == .maintenance)
    }

    @Test func deepLinkSelectsBeforePresenting() {
        let router = SettingsRouter(defaults: makeDefaults())
        var tabWhenPresented: SettingsTab?
        router.open(.sources) { tabWhenPresented = router.selectedTab }
        #expect(tabWhenPresented == .sources)
    }

    // MARK: Scene and call sites

    @Test func settingsIsTheSwiftUISceneNotAnAppKitWindow() throws {
        let app = try source("MLM/App/MLMApp.swift")
        #expect(app.contains("Settings {"))
        #expect(!app.contains("replacing: .appSettings"), "the Settings scene supplies Settings… ⌘,")
        let delegate = try source("MLM/App/AppDelegate.swift")
        #expect(!delegate.contains("showSettingsWindow"))
        #expect(!delegate.contains("rootView: SettingsView()"))
    }

    @Test func everyOpenSettingsCallSiteNamesItsTab() throws {
        let expectations: [(String, String, Int)] = [
            ("MLM/Views/Sidebar/LibraryFooter.swift", "openSettings(tab: .library)", 1),
            ("MLM/Views/Playlists/PlaylistDetailView.swift", "openSettings(tab: .sources)", 1),
            // W3-ADD: the import sheets' Settings links go through one host (the remote window is gone).
            ("MLM/Views/Import/ImportSheetsHost.swift", "openSettings(tab: .sources)", 1),
            ("MLM/Views/Settings/SourcesSetupView.swift", "openSettings(tab: .sources)", 1),
        ]
        for (path, call, count) in expectations {
            let src = try source(path)
            #expect(src.components(separatedBy: call).count - 1 == count, "\(path) should call \(call) \(count)×")
            #expect(!src.contains("showSettingsWindow"))
        }
    }
}
