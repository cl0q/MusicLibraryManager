import SwiftUI

// MARK: - Content scaffold (UC-LAYOUT-01…05)

/// The frame every content view of the main window sits in. Top to bottom:
///
/// 1. **banner slot** — window-level state only (the drive, UC-LAYOUT-02); shown when
///    `showsDriveBanner` is true and the library's disk is not connected
/// 2. **detail header** — pushed details and sync profiles (`header`)
/// 3. **scope bar** — the view's filters (`scopeBar`)
/// 4. **content** — table / list / grid / form
/// 5. **selection bar** — floats over the bottom of the content (`selectionBar`, W2-G); it
///    never shrinks the table and never covers the status bar
/// 6. **status bar** — counts (declared by the content with `.statusBarText(_:)`) and the
///    transient messages of `StatusBarCenter`
///
/// ```swift
/// ContentScaffold(showsDriveBanner: true) {
///     MyTable()
///         .statusBarText(StatusBarText.tracks(count))
/// } scopeBar: {
///     MyScopeBar()
/// }
/// ```
struct ContentScaffold<Content: View, Header: View, ScopeBar: View, SelectionBar: View>: View {
    let showsDriveBanner: Bool
    let content: Content
    let header: Header
    let scopeBar: ScopeBar
    let selectionBar: SelectionBar

    @State private var defaultStatusText: String?

    init(
        showsDriveBanner: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder scopeBar: () -> ScopeBar = { EmptyView() },
        @ViewBuilder selectionBar: () -> SelectionBar = { EmptyView() }
    ) {
        self.showsDriveBanner = showsDriveBanner
        self.content = content()
        self.header = header()
        self.scopeBar = scopeBar()
        self.selectionBar = selectionBar()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                selectionBar
                    .padding(.bottom, Spacing.m)
            }
            .onPreferenceChange(StatusBarTextKey.self) { defaultStatusText = $0 }
            // The text belongs to this scaffold; don't let it reach an outer one.
            .transformPreference(StatusBarTextKey.self) { $0 = nil }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if showsDriveBanner {
                        DriveBanner()
                    }
                    header
                    scopeBar
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(defaultText: defaultStatusText)
            }
    }
}

// MARK: - Status bar view (P-STATUSBAR)

/// 24 pt opaque bar with a top separator (UC-STATUS-01). Shows, left to right: the loading
/// spinner and phase after 300 ms (UC-STATUS-06), then either the current message with its
/// buttons or the default text.
struct StatusBar: View {
    let defaultText: String?

    @Environment(StatusBarCenter.self) private var center

    var body: some View {
        HStack(spacing: Spacing.s) {
            if center.isLoadingVisible {
                ProgressView()
                    .controlSize(.small)
                if let phase = center.loadingPhase {
                    Text(phase)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = center.message {
                Text(message.text)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(message.actions) { action in
                    Button(action.title) {
                        center.perform(action)
                    }
                    .buttonStyle(.link)
                }
            } else if let defaultText {
                Text(defaultText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.m)
        .frame(height: ShellMetrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }
}

// MARK: - Drive banner (UC-STATE §15.2, DEC-014)

/// The library's disk as the window sees it. `volumeName` is `nil` for a library folder on
/// the Mac's own disk (never "not connected").
struct LibraryDriveState: Equatable {
    var volumeName: String?
    var isConnected: Bool

    var isOffline: Bool { volumeName != nil && !isConnected }

    /// `/Volumes/Lexxar` → `Lexxar`.
    static func volumeName(fromVolumePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    @MainActor
    static func current(_ container: DependencyContainer) -> LibraryDriveState {
        LibraryDriveState(
            volumeName: volumeName(fromVolumePath: container.mountObserver?.libraryVolumePath),
            isConnected: container.isLibraryDriveMounted
        )
    }

    /// `“Lexxar” is not connected. You can browse, edit and queue downloads; playback and
    /// file actions are paused.` (§15.2, C17: THOUGHTS wording)
    static func bannerSubject(_ name: String) -> String { "“\(name)” is not connected." }
    static let bannerConsequence = "You can browse, edit and queue downloads; playback and file actions are paused."

    /// Sidebar-footer wording: `“Lexxar” — not connected`.
    static func footerText(_ name: String) -> String { "“\(name)” — not connected" }

    /// Status-bar message when the disk returns: `“Lexxar” connected.`
    static func connectedMessage(_ name: String) -> String { "“\(name)” connected." }
}

/// One banner per window, in every view that lists tracks, while the library's disk is away.
/// Quiet tinted opaque fill, orange symbol, `Try Again` (UC-COLOR-10, §15.2).
struct DriveBanner: View {
    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar

    var body: some View {
        let state = LibraryDriveState.current(container)
        if state.isOffline, let name = state.volumeName {
            HStack(spacing: Spacing.s) {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("\(Text(LibraryDriveState.bannerSubject(name)).fontWeight(.semibold)) \(LibraryDriveState.bannerConsequence)")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                Button("Try Again") {
                    retry(name: name)
                }
            }
            .font(.callout)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background {
                ZStack {
                    Rectangle().fill(.background)
                    Rectangle().fill(.quaternary)
                }
            }
            .overlay(alignment: .bottom) {
                Divider()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// VoiceOver announcement when the disk goes away (UC-A11Y-05); posted once per event by
    /// the window, not by each banner instance.
    static func announceDisconnected(_ name: String) {
        AccessibilityNotification.Announcement(
            "\(LibraryDriveState.bannerSubject(name)) \(LibraryDriveState.bannerConsequence)"
        ).post()
    }

    private func retry(name: String) {
        guard let observer = container.mountObserver else { return }
        if observer.checkMountStatus() {
            container.isLibraryDriveMounted = true
            statusBar.post(LibraryDriveState.connectedMessage(name))
        }
    }
}
