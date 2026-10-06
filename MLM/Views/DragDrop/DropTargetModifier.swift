import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - A drop target (UC-DND-03/04/05, PATTERN-DND.N02/N03)

extension View {
    /// Makes this view a drop target of the UC-DND matrix: while a drag it takes hovers, the
    /// accent ring and the copy cursor; one it doesn't take gets no ring and the not-allowed
    /// cursor. The drop is loaded, decided (`DropRules`) and run through the existing commands
    /// (`DropPerformer`) — one undo step, a status-bar confirmation, never navigation.
    ///
    /// - Parameters:
    ///   - target: what this view is in the matrix.
    ///   - cornerRadius: the ring's corner (UC-SPACE-04: 4 / 7 / 9).
    ///   - isShown: the target is the place on screen (a spring-load would do nothing).
    ///   - springLoad: opens the target while a track drag rests on it (system timing; offered,
    ///     never required — the target takes the drop itself).
    ///   - sayRefusal: where a refusal is said; nil = the status bar.
    func dropTarget(
        _ target: DropTarget,
        cornerRadius: CGFloat = 7,
        isShown: Bool = false,
        springLoad: (() -> Void)? = nil,
        sayRefusal: ((String) -> Void)? = nil
    ) -> some View {
        modifier(DropTargetModifier(target: target, cornerRadius: cornerRadius, isShown: isShown,
                                    springLoad: springLoad, sayRefusal: sayRefusal))
    }
}

private struct DropTargetModifier: ViewModifier {
    let target: DropTarget
    let cornerRadius: CGFloat
    let isShown: Bool
    let springLoad: (() -> Void)?
    let sayRefusal: ((String) -> Void)?

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    @State private var isTargeted = false
    @State private var spring = SpringLoadingTimer()

    func body(content: Content) -> some View {
        content
            .overlay {
                // The accent ring (UC-COLOR-04); no pulse, no animation (UC-MOTION-01).
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: DropRules.observedTypes, delegate: DropTargetDelegate(
                target: target,
                isShown: isShown,
                context: { DropContext.current(container) },
                isTargeted: $isTargeted,
                spring: spring,
                springLoad: springLoad,
                perform: { content in
                    let decision = DropRules.decide(content, onto: target, context: DropContext.current(container))
                    performer.perform(decision)
                }
            ))
    }

    private var performer: DropPerformer {
        DropPerformer(container: container, shell: shell, statusBar: statusBar, undo: undo ?? .main, sayRefusal: sayRefusal)
    }
}

/// The delegate behind `dropTarget`: decides from the pasteboard types while hovering,
/// loads only on the drop.
private struct DropTargetDelegate: DropDelegate {
    let target: DropTarget
    let isShown: Bool
    let context: @MainActor () -> DropContext
    @Binding var isTargeted: Bool
    let spring: SpringLoadingTimer
    let springLoad: (() -> Void)?
    let perform: @MainActor (DropContent) -> Void

    private func kind(_ info: DropInfo) -> DragKind {
        DropRules.hoverKind { info.hasItemsConforming(to: [$0]) }
    }

    private func accepts(_ info: DropInfo) -> Bool {
        DropRules.accepts(kind(info), on: target, context: context())
    }

    func dropEntered(info: DropInfo) {
        let kind = kind(info)
        isTargeted = DropRules.accepts(kind, on: target, context: context())
        if let springLoad, isTargeted, DropRules.springLoads(kind, on: target, isShown: isShown) {
            spring.start(springLoad)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Copy (+): the source keeps what it had (UC-DND-07); refused: not allowed.
        DropProposal(operation: accepts(info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        spring.cancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        spring.cancel()
        guard accepts(info) else { return false }
        let providers = info.itemProviders(for: DropRules.observedTypes)
        let perform = self.perform
        Task { @MainActor in
            if let content = await DropLoader.load(providers) { perform(content) }
        }
        return true
    }
}

extension DropContext {
    /// The open window's state, read now.
    @MainActor
    static func current(_ container: DependencyContainer) -> DropContext {
        let drive = LibraryDriveState.current(container)
        return DropContext(
            libraryID: container.activeLibrary?.libraryId,
            isLibraryOpen: container.isInitialized,
            offlineVolumeName: drive.isOffline ? drive.volumeName : nil
        )
    }
}

// MARK: - Spring-loading (D-SIDEBAR-SPRINGLOAD, D-PL-SPRINGLOAD-CARD)

/// Opens a target after a drag has rested on it for the system's spring-loading delay — and
/// not at all when spring-loading is off in System Settings. Replaces the old pulsing outline
/// (UC-MOTION-01): the ring is the only feedback.
@MainActor
final class SpringLoadingTimer {
    private var task: Task<Void, Never>?

    func start(_ action: @escaping () -> Void) {
        task?.cancel()
        guard let delay = SpringLoading.delay(UserDefaults.standard) else { return }
        task = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

enum SpringLoading {
    /// The system spring-loading delay in seconds (Accessibility ▸ Pointer Control), nil when
    /// spring-loading is off. Global-domain keys `com.apple.springing.enabled` / `.delay`.
    static func delay(_ defaults: UserDefaults) -> Double? {
        if let enabled = defaults.object(forKey: "com.apple.springing.enabled") as? Bool, !enabled { return nil }
        let delay = defaults.object(forKey: "com.apple.springing.delay") as? Double ?? defaultDelay
        return min(max(delay, 0.1), 2)
    }

    /// Finder's default when the user never moved the slider.
    static let defaultDelay = 0.5
}

// MARK: - The main window (D-LIBFILE-WINDOWDROP, D-REMOTE-URL-DROP, D-LIB-FINDER-IN, M3U)

extension View {
    /// The window as the last drop target: Finder audio files and folders import, a link goes
    /// to Add from Link…, a `.mlibm` opens or switches the library, an `.m3u` shows its preview
    /// sheet (hosted here so a drop on a sidebar row never navigates). In launch states only a
    /// library file is taken.
    func mainWindowDrops() -> some View {
        modifier(MainWindowDrops())
    }
}

private struct MainWindowDrops: ViewModifier {
    func body(content: Content) -> some View {
        content
            .dropTarget(.window, cornerRadius: 0)
            // The M3U preview, file panel and export (W3-PL, `PlaylistM3UImportSheet.swift`).
            .playlistWindowRequests()
    }
}

// MARK: - A refusal said in place (UC-SURF-04: a refused cover drop, 5 s)

extension View {
    /// Shows `message` over the bottom of this view (a cover) for 5 s — the refused cover drop's
    /// sentence where it was dropped, not a toast (UC-SHEET-23).
    func inPlaceRefusal(_ message: Binding<String?>) -> some View {
        modifier(InPlaceRefusal(message: message))
    }
}

private struct InPlaceRefusal: ViewModifier {
    @Binding var message: String?

    static let duration: Duration = .seconds(5)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Label {
                        Text(message)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .padding(Spacing.xs)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(Spacing.xs)
                    .accessibilityAddTraits(.isStaticText)
                    .task(id: message) {
                        // Said for VoiceOver too: the sentence appears where nothing has focus.
                        AccessibilityNotification.Announcement(message).post()
                        try? await Task.sleep(for: Self.duration)
                        if !Task.isCancelled { self.message = nil }
                    }
                }
            }
    }
}
