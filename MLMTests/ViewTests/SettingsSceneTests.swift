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
        // W3-SET: Storage Location and Advanced keep their rows for this Mac usable and dim only
        // their per-library sections.
        #expect(SettingsTab.allCases.filter(\.belongsToLibrary) == [.library, .backup, .maintenance])
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
                     "BackupSettingsView()", "DataLocationsView()", "MaintenanceView()", "AdvancedSettingsView()"] {
            #expect(src.contains(pane), "pane \(pane) must be hosted")
        }
        // The genre tools left Settings for the Genres destination (W3-GEN, DEC-025, ST-ADV).
        let advanced = try source("MLM/Views/Settings/AdvancedSettingsView.swift")
        #expect(!advanced.contains("GrooveStudioView"))
        #expect(!advanced.contains("genre tools move"))
        #expect(!advanced.contains("Genre Workshop"), "retired word (UC-GLOSS-02)")
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
            // W3-SET: Sources no longer links to itself; the other call sites, each on its tab.
            ("MLM/Views/Settings/SourcesSetupView.swift", "openSettings(tab: .sources)", 0),
            ("MLM/Views/Library/LibraryView.swift", "openSettings(tab: .library)", 1),
            ("MLM/Views/Inspector/InspectorAudioTab.swift", "openSettings(tab: .sources)", 1),
            ("MLM/Views/Search/OnlineSearchResultsView.swift", "openSettings(tab: .sources)", 2),
            ("MLM/Views/Activity/ActivityToolbarItem.swift", "openSettings(tab: .backup)", 1),
            ("MLM/Views/Launch/LibrarySetupFlowView.swift", "openSettings(tab: .library)", 1),
            ("MLM/App/Commands/LibraryMenuCommands.swift", "openSettings(tab: .maintenance)", 1),
            ("MLM/App/Commands/LibraryMenuCommands.swift", "openSettings(tab: .library)", 1),
            ("MLM/App/Commands/LibraryMenuCommands.swift", "openSettings(tab: .backup)", 2),
        ]
        for (path, call, count) in expectations {
            let src = try source(path)
            #expect(src.components(separatedBy: call).count - 1 == count, "\(path) should call \(call) \(count)×")
            #expect(!src.contains("showSettingsWindow"))
        }
    }

    // MARK: W3-SET

    @Test func everyTabIsANativeGroupedForm() throws {
        for file in ["GeneralSettingsView", "LibrarySetupView", "PlaybackSettingsView", "SourcesSetupView",
                     "BackupSettingsView", "DataLocationsView", "MaintenanceView", "AdvancedSettingsView"] {
            let src = try source("MLM/Views/Settings/\(file).swift")
            #expect(src.contains(".formStyle(.grouped)"), "\(file)")
            #expect(!src.contains("MLMFont") && src.range(of: #"\.mlm[A-Z]"#, options: .regularExpression) == nil,
                    "\(file): no mlm tokens (W5-4 / brief §3)")
            #expect(!src.contains("NSOpenPanel"), "\(file): system panels via .fileImporter (UC-SHEET-24)")
        }
    }

    @Test func playbackHasNoSpaceBarPointer() throws {
        let src = try source("MLM/Views/Settings/PlaybackSettingsView.swift")
        #expect(!src.localizedCaseInsensitiveContains("space bar"), "§10 Q1")
        #expect(src.contains("Keep the last played tracks"))
        #expect(src.contains("When playing from a list, queue up to"))
        #expect(src.contains("\"playback_history_size\"") && src.contains("\"playback_context_cap\""))
    }

    @Test func settingsAlertsHaveCancelAsDefault() throws {
        for file in ["SourcesSetupView", "BackupSettingsView", "MaintenanceView"] {
            let src = try source("MLM/Views/Settings/\(file).swift")
            let destructive = src.components(separatedBy: "role: .destructive)").count - 1
            #expect(destructive > 0, "\(file)")
            #expect(src.contains("Button(\"Cancel\", role: .cancel)"), "\(file)")
        }
        let sources = try source("MLM/Views/Settings/SourcesSetupView.swift")
        #expect(sources.contains("Clear the Qobuz access cookie?"), "A-SET-COOKIECLEAR")
        #expect(sources.contains("for all libraries. Linked playlists stay in your library but can’t be refreshed until you connect again."),
                "A-SET-DISCONNECT")
        let maintenance = try source("MLM/Views/Settings/MaintenanceView.swift")
        for title in ["Update organized paths?", "Roll back last path migration?", "Clear the transcode cache?"] {
            #expect(maintenance.contains(title))
        }
    }
}
