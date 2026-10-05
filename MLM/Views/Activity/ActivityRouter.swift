import AppKit
import Observation
import SwiftUI

/// Where the Activity surfaces are opened from: the toolbar popover (also from the status
/// bar's `Show`), the Activity window's tab, and a deep link into the logs (`Show in Logs`).
@MainActor
@Observable
final class ActivityRouter {
    static let shared = ActivityRouter()

    enum Tab: String, CaseIterable, Identifiable {
        case operations = "Operations"
        case logs = "Logs"
        var id: String { rawValue }
    }

    /// The window's remembered tab.
    static let tabKey = "activity.window.tab"

    /// The toolbar item's popover.
    var isPopoverPresented = false
    var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    /// The logs pre-filtered to one operation (`Show in Logs`); `nil` = all lines.
    var logFocus: ActivityLogFocus?
    /// Bumped to ask the main window to open the Activity window (from places without
    /// `openWindow`, e.g. a status-bar button).
    private(set) var windowRequest = 0
    /// Operation to select in the Operations table when the window opens.
    var selectedOperationID: UUID?

    init() {
        tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(Tab.init(rawValue:)) ?? .operations
    }

    func showPopover() { isPopoverPresented = true }

    func requestWindow(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        windowRequest += 1
    }

    /// `Show in Logs`: the Logs tab, filtered to the operation's time span.
    func showLogs(for operation: ActivityOperation?) {
        logFocus = operation.map(ActivityLogFocus.init)
        tab = .logs
    }
}

/// The time span and name of one operation, for the logs' deep-link filter
/// (P-ACTIVITY-LOGS.N01).
struct ActivityLogFocus: Equatable {
    let operationID: UUID
    let title: String
    let start: Date
    let end: Date?

    init(_ operation: ActivityOperation) {
        operationID = operation.id
        title = operation.title
        start = operation.startedAt.addingTimeInterval(-1)
        end = operation.endedAt?.addingTimeInterval(1)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && (end.map { date <= $0 } ?? true)
    }
}

// MARK: - Opening a subject (UC-PRIM-13) — an explicit user action, never on finish

@MainActor
enum ActivitySubjectNavigator {
    /// Opens the subject in the main window (bringing it forward), Settings or Finder.
    static func open(_ subject: ActivitySubject, openWindow: OpenWindowAction, openSettings: OpenSettingsAction,
                     container: DependencyContainer = .shared) {
        guard subject.isLinkable else { return }
        if let tab = subject.settingsTab {
            openSettings(tab: tab)
            return
        }
        if subject.kind == .libraryFile {
            if let url = container.activeLibrary?.packageURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        guard let destination = destination(for: subject) else { return }
        openWindow(id: MainWindow.id)
        ShellWindowModels.main.navigation?.select(destination)
    }

    static func destination(for subject: ActivitySubject) -> SidebarDestination? {
        switch subject.kind {
        case .playlist: return subject.id.map { .playlist($0) }
        case .syncProfile: return subject.id.map { .syncProfile($0) }
        case .tracks, .allTracks: return .allTracks
        case .folder: return .folders
        case .review: return .review
        case .discover, .reels: return .discover
        case .genres: return .genres
        case .none, .settings, .libraryFile: return nil
        }
    }

    /// The one fix of a Needs-attention group (UC-JOB-11).
    static func perform(_ fix: ActivityFix, group: ActivityPresentation.AttentionGroup, center: ActivityCenter,
                        openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        switch fix {
        case .openSettings(let raw):
            openSettings(tab: SettingsTab(rawValue: raw) ?? .general)
        case .reconnect:
            openSettings(tab: .sources)
        case .retry:
            retry(group, center: center)
        case .showTracks:
            open(.tracks(group.trackIDs), openWindow: openWindow, openSettings: openSettings)
        case .runAgain:
            for id in group.operationIDs { center.operation(id: id)?.controls.runAgain?() }
        case .waitForDrive:
            break
        }
    }

    /// `Retry All`: every retryable failed track of the group, once.
    static func retry(_ group: ActivityPresentation.AttentionGroup, center: ActivityCenter) {
        guard group.isRetryable else { return }
        if group.trackIDs.isEmpty {
            for id in group.operationIDs { center.operation(id: id)?.controls.runAgain?() }
            return
        }
        // One batch for the whole group, through the newest operation's retry.
        if let newest = group.operationIDs.first {
            center.retryFailed(newest, trackIDs: group.trackIDs)
        }
    }
}
