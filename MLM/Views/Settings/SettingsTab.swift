import Observation
import SwiftUI

// MARK: - Settings tabs (W-SETTINGS, UC-WIN-03, DEC-035)

/// The eight tabs of the Settings scene, in display order (UC-WIN-03). The raw values are the
/// persisted tab tags; the seven older ones are unchanged, so a remembered tab survives.
///
/// **Deep links:** open Settings at a tab with `openSettings(tab: .sources)` from any view
/// (`@Environment(\.openSettings) private var openSettings`). Pick the tab that fixes the
/// problem the caller shows: download tools and sign-ins → `.sources`, the library folder →
/// `.library`, backups → `.backup`, analysis jobs → `.maintenance`.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case library
    case playback
    case sources
    case backup
    case storage
    case maintenance
    case advanced

    var id: String { rawValue }

    /// Tab name — also the Settings window's title while the tab is selected (system).
    var title: String {
        switch self {
        case .general: "General"
        case .library: "Library"
        case .playback: "Playback"
        case .sources: "Sources"
        case .backup: "Backup"
        case .storage: "Storage Location"
        case .maintenance: "Maintenance"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .library: "music.note.house"
        case .playback: "play.circle"
        case .sources: "antenna.radiowaves.left.and.right"
        case .backup: "externaldrive.badge.timemachine"
        case .storage: "internaldrive"
        case .maintenance: "wrench.and.screwdriver"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// Whether the tab's settings belong to the open library, so they are dimmed while no
    /// library is open (UC-WIN-05). General, Playback and Sources (accounts and tools of this
    /// Mac) keep working. Advanced still hosts the Genre Workshop, which reads the library;
    /// W3-SET turns it into an app-wide tab.
    var belongsToLibrary: Bool {
        switch self {
        case .general, .playback, .sources: false
        case .library, .backup, .storage, .maintenance, .advanced: true
        }
    }
}

// MARK: - Router

/// The Settings scene's selected tab, shared by the tab view and every deep link.
///
/// - The selection persists (`settings.selectedTab`), so ⌘, opens on the last-used tab.
/// - `select(_:)` changes it; a deep link selects first and then opens the window, so the
///   window comes forward on the requested tab even when it was already open elsewhere.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    /// The `@AppStorage` key the old AppKit window used; kept so the remembered tab survives.
    static let selectedTabKey = "settings.selectedTab"

    @ObservationIgnored private let defaults: UserDefaults

    var selectedTab: SettingsTab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Self.selectedTabKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedTab = defaults.string(forKey: Self.selectedTabKey)
            .flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func select(_ tab: SettingsTab) {
        if selectedTab != tab { selectedTab = tab }
    }

    /// Select `tab`, then present Settings with `present` (the environment's `openSettings`).
    func open(_ tab: SettingsTab, present: () -> Void) {
        select(tab)
        present()
    }
}

extension OpenSettingsAction {
    /// Open Settings at `tab` (deep link, DEC-035; fixes PP-SHELL-33).
    @MainActor
    func callAsFunction(tab: SettingsTab) {
        SettingsRouter.shared.open(tab) { self() }
    }
}
