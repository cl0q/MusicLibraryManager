import Testing
import Foundation
@testable import MLM

/// W1-2 review B2: the main window comes forward whenever a library flow needs it (UC-WIN-01).
@Suite("Main window comes forward (W1-2 review)")
struct MainWindowPresenterTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func newLibraryPresentationsBringTheWindow() {
        let none = LibraryWindowNeeds()
        #expect(LibraryWindowNeeds.mustShowWindow(before: none, after: LibraryWindowNeeds(pendingSwitch: true)))
        #expect(LibraryWindowNeeds.mustShowWindow(before: none, after: LibraryWindowNeeds(switchProblem: true)))
        #expect(LibraryWindowNeeds.mustShowWindow(before: none, after: LibraryWindowNeeds(newLibraryRequest: true)))
        #expect(LibraryWindowNeeds.mustShowWindow(before: LibraryWindowNeeds(pendingSwitch: true),
                                                  after: LibraryWindowNeeds(pendingSwitch: true, switchProblem: true)))
    }

    @Test func goingAwayOrStayingDoesNot() {
        let up = LibraryWindowNeeds(pendingSwitch: true)
        #expect(!LibraryWindowNeeds.mustShowWindow(before: up, after: up))
        #expect(!LibraryWindowNeeds.mustShowWindow(before: up, after: LibraryWindowNeeds()))
        #expect(!LibraryWindowNeeds.mustShowWindow(before: LibraryWindowNeeds(), after: LibraryWindowNeeds()))
    }

    @Test func everyLibraryRouteGoesThroughThePresenter() throws {
        let delegate = try source("MLM/App/AppDelegate.swift")
        #expect(delegate.contains("MainWindowPresenter.shared.openLibrary(url, launch: LibraryLaunchCoordinator.shared)"))
        #expect(delegate.contains("MainWindowPresenter.shared.watch(LibraryLaunchCoordinator.shared)"))
        #expect(delegate.contains("func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool"))
        let file = try source("MLM/App/LibraryCommands.swift")
        #expect(!file.contains("launch.handleOpen(") && !file.contains("launch.requestNewLibrary()"))
        #expect(file.contains("MainWindowPresenter.shared.requestNewLibrary(launch: launch)"))
        let dock = try source("MLM/App/Commands/DockMenu.swift")
        #expect(dock.contains("MainWindowPresenter.shared.openLibrary(url, launch: .shared)"))
        let settings = try source("MLM/Views/Settings/SettingsView.swift")
        #expect(settings.contains("MainWindowPresenter.shared.openLibrary(url, launch: .shared)"))
        #expect(settings.contains(".installsMainWindowPresenter()"))
        let content = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(content.contains(".installsMainWindowPresenter()"))
        let presenter = try source("MLM/App/Commands/MainWindowPresenter.swift")
        #expect(presenter.contains("openWindow(id: MainWindow.id)"), "the one main window, never a second")
    }
}

