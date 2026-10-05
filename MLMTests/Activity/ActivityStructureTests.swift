import Foundation
import Testing
@testable import MLM

/// Source checks of the rebuilt Activity surfaces (W3-ACT; replaces `ActivityPanelStructureTests`
/// of the removed bottom panel): system containers only, no `mlm*` tokens or custom fonts, the
/// panel and its Esc button are gone, Window ▸ Activity opens the window.
@Suite("ActivityStructureTests")
struct ActivityStructureTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let rebuilt = [
        "MLM/Views/Activity/ActivityToolbarItem.swift",
        "MLM/Views/Activity/ActivityWindow.swift",
        "MLM/Views/Activity/ActivityLogsView.swift",
        "MLM/Views/Activity/ActivityRouter.swift",
        "MLM/Views/Activity/LogTextRenderer.swift",
        "MLM/Views/Activity/LogFeed.swift",
    ]

    @Test func rebuiltFilesUseSystemStylesOnly() throws {
        for path in Self.rebuilt {
            let text = try source(path)
            #expect(!text.contains(".mlm"), "\(path): no mlm* tokens (UC-COLOR-03)")
            #expect(!text.contains("MLMFont"), "\(path): no custom fonts (UC-TYPE-01)")
            #expect(!text.contains(".font(.system(size:"), "\(path): no point sizes (UC-TYPE-01)")
            #expect(!text.contains("Color(red:"), "\(path): no literal colours (UC-COLOR-02)")
            #expect(!text.contains("Material"), "\(path): no custom material (UC-GLASS-06)")
            #expect(!text.contains("glassEffect"), "\(path): no glass (UC-GLASS-06)")
            #expect(text.range(of: "(^|[^A-Za-z])print\\(", options: .regularExpression) == nil, "\(path): no print — use AppLogger")
            #expect(!text.contains("#available"), "\(path): no availability checks")
        }
    }

    @Test func theBottomPanelAndItsEscButtonAreGone() throws {
        let fm = FileManager.default
        for removed in ["MLM/Views/Activity/ActivityPanel.swift", "MLM/Views/Activity/OperationsTab.swift",
                        "MLM/Views/Activity/ActivityFeed.swift", "MLM/Views/Activity/ActivityFeedAdapters.swift",
                        "MLM/Views/Activity/LogsTab.swift", "MLM/ViewModels/ActivityViewModel.swift"] {
            #expect(!fm.fileExists(atPath: Self.repoRoot.appendingPathComponent(removed).path), "\(removed) is removed")
        }
        let content = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(!content.contains("ActivityPanel"))
        #expect(!content.contains("activity.panel.expanded"))
        // K-ACT-ESC removed: Esc belongs to the popover (system), never a hidden button.
        for path in Self.rebuilt {
            #expect(!(try source(path)).contains(".keyboardShortcut(.escape"), "\(path): no hidden Esc button")
        }
    }

    @Test func windowActivityOpensTheWindowInEveryLaunchState() throws {
        let window = try source("MLM/App/Commands/WindowCommands.swift")
        #expect(window.contains("CommandButton(.activity, enabled: true)"))
        #expect(window.contains("openWindow(id: ActivityWindow.id)"))
        let app = try source("MLM/App/MLMApp.swift")
        #expect(app.contains("Window(ActivityWindow.title, id: ActivityWindow.id)"))
        #expect(ActivityWindow.id == "activity")
        #expect(MenuCommand.activity.shortcut?.keyboardShortcut == .init("0", modifiers: [.option, .command]))
        // Launch states show the Activity item too (UC-WIN-07).
        let content = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(content.contains("if !container.isInitialized {\n                ToolbarItem(placement: .primaryAction) {\n                    ActivityToolbarItem()"))
    }

    @Test func toolbarItemHonoursReduceMotionAndCollapses() throws {
        let item = try source("MLM/Views/Activity/ActivityToolbarItem.swift")
        #expect(item.contains("accessibilityReduceMotion"))
        #expect(item.contains(".symbolEffect(.bounce, value: center.finishedCount)"))
        #expect(item.contains("ViewThatFits(in: .horizontal)"))
        #expect(item.contains(".accessibilityValue(summary.sentence)"))
    }

    @Test func aFinishedJobNeverNavigatesOrOpensAWindow() throws {
        // The center has no navigation, window or focus API at all (UC-JOB-12, N16).
        let center = try source("MLM/Services/Activity/ActivityCenter.swift")
        for forbidden in ["openWindow", "NavigationModel", "makeKeyAndOrderFront", "activate(", "isPopoverPresented"] {
            #expect(!center.contains(forbidden), "ActivityCenter must not use \(forbidden)")
        }
    }

    @Test func logLevelWordsAreTheDesignWords() {
        #expect(LogLevelFilter.allCases.map(\.label) == ["All", "Info and above", "Warnings and above", "Errors", "Debug only"])
        #expect(LogSourceFilter(storageValue: LogSourceFilter.exact("Sync").storageValue) == .exact("Sync"))
        #expect(LogSourceFilter(storageValue: LogSourceFilter.all.storageValue) == .all)
    }
}
