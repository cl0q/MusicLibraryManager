import Observation
import SwiftUI

// MARK: - Status bar contract (P-STATUSBAR, UC-STATUS-01…07, DEC-016)

/// A button inside a transient status-bar message (`Undo`, `Show`, `Try Again`, `Download`,
/// `Locate…`, `Cancel`, `Resume`; UC-STATUS-04). Title Case, no ellipsis unless it asks for
/// more (UC-COPY-02/05).
struct StatusAction: Identifiable {
    let id = UUID()
    let title: String
    let perform: @MainActor () -> Void

    init(_ title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }

    /// The `Undo` button. Bind it to the same undo step as Edit ▸ Undo (UC-STATUS-04);
    /// W2-F supplies the `UndoManager` integration, this is only the hook.
    static func undo(_ perform: @escaping @MainActor () -> Void) -> StatusAction {
        StatusAction("Undo", perform: perform)
    }
}

/// One transient message: what happened, plus at most two buttons.
struct StatusMessage: Identifiable {
    let id = UUID()
    /// Sentence fragment without a final period (UC-COPY-04), e.g.
    /// `Removed 9 tracks from “Warm-up” — the files stay in the library`.
    let text: String
    /// Zero to two buttons, in display order.
    let actions: [StatusAction]
}

/// The window's status bar centre: transient "it happened" messages and the delayed
/// loading indicator. One instance per main window, in the environment
/// (`@Environment(StatusBarCenter.self)`) and as `@FocusedValue(\.statusBarCenter)`.
///
/// **Default text** (counts, UC-STATUS-02/03) is not stored here: the view that owns the
/// content declares it with `.statusBarText(_:)` and the scaffold's status bar shows it
/// whenever no message is up. That keeps it correct for whichever view is visible.
///
/// **Messages** (UC-STATUS-04):
/// ```swift
/// statusBar.post("Added 3 tracks to “Warm-up”", actions: [.undo { undoManager?.undo() }])
/// ```
/// - A message replaces the default text for 8 s (`messageLifetime`), then the default returns.
/// - A newer message replaces the current one at once (and restarts the 8 s).
/// - At most two actions are kept; extra ones are dropped.
/// - Pressing an action runs it and clears the message.
/// - Every message is announced to VoiceOver (UC-A11Y-05).
///
/// **Loading** (UC-STATUS-06): wrap work that refreshes the visible view in
/// `let token = beginLoading("Refreshing from SoundCloud…")` … `endLoading(token)`. The spinner
/// and phase text appear only if the work is still running after 300 ms (`loadingDelay`).
@MainActor
@Observable
final class StatusBarCenter {
    static let messageLifetime: Duration = .seconds(8)
    static let loadingDelay: Duration = .milliseconds(300)
    static let maximumActions = 2

    /// The message on screen, or `nil` when the default text shows.
    private(set) var message: StatusMessage?

    /// True once a loading operation has run longer than `loadingDelay`.
    private(set) var isLoadingVisible = false

    /// Phase text of the most recently started loading operation (`Refreshing…`).
    private(set) var loadingPhase: String?

    /// Opaque handle for `endLoading(_:)`.
    struct LoadingToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var activeLoads: [LoadingToken: String] = [:]
    @ObservationIgnored private var loadOrder: [LoadingToken] = []

    /// The pending expiry of the current message (exposed for tests).
    @ObservationIgnored private(set) var expiryTask: Task<Void, Never>?
    /// The pending 300 ms reveal of the loading indicator (exposed for tests).
    @ObservationIgnored private(set) var loadingRevealTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sleep: suspends for a duration; injectable so tests control time.
    ///   - announce: VoiceOver announcement of a new message.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.sleep = sleep
        self.announce = announce
    }

    // MARK: Messages

    /// Show `text` with up to two buttons for 8 s, replacing any current message at once.
    @discardableResult
    func post(_ text: String, actions: [StatusAction] = []) -> StatusMessage.ID {
        let newMessage = StatusMessage(text: text, actions: Array(actions.prefix(Self.maximumActions)))
        message = newMessage
        announce(text)
        expiryTask?.cancel()
        let id = newMessage.id
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            do {
                try await sleep(Self.messageLifetime)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        return id
    }

    /// Remove the message with `id` if it is still the one on screen.
    func dismiss(_ id: StatusMessage.ID) {
        guard message?.id == id else { return }
        message = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    /// Run a button of the current message and clear the message.
    func perform(_ action: StatusAction) {
        if let id = message?.id, message?.actions.contains(where: { $0.id == action.id }) == true {
            dismiss(id)
        }
        action.perform()
    }

    private func expire(_ id: StatusMessage.ID) {
        guard message?.id == id else { return }
        message = nil
        expiryTask = nil
    }

    // MARK: Loading

    /// Start a loading phase for the visible view. Shows after 300 ms if not ended by then.
    func beginLoading(_ phase: String) -> LoadingToken {
        let token = LoadingToken()
        activeLoads[token] = phase
        loadOrder.append(token)
        loadingPhase = phase
        if loadingRevealTask == nil, !isLoadingVisible {
            let sleep = self.sleep
            loadingRevealTask = Task { [weak self] in
                do {
                    try await sleep(Self.loadingDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.revealLoading()
            }
        }
        return token
    }

    /// End a loading phase started with `beginLoading(_:)`. Unknown tokens are ignored.
    func endLoading(_ token: LoadingToken) {
        guard activeLoads.removeValue(forKey: token) != nil else { return }
        loadOrder.removeAll { $0 == token }
        if let latest = loadOrder.last {
            loadingPhase = activeLoads[latest]
        } else {
            loadingPhase = nil
            isLoadingVisible = false
            loadingRevealTask?.cancel()
            loadingRevealTask = nil
        }
    }

    private func revealLoading() {
        loadingRevealTask = nil
        if !activeLoads.isEmpty { isLoadingVisible = true }
    }
}

// MARK: - Default text

/// Default status-bar text of the content view (counts). Declared by the content, read by
/// the scaffold's status bar; the innermost declaration wins.
struct StatusBarTextKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Declare the status bar's default text for this content (UC-STATUS-02/03), e.g.
    /// `.statusBarText(StatusBarText.tracks(12_935))`. `nil` leaves it empty.
    func statusBarText(_ text: String?) -> some View {
        preference(key: StatusBarTextKey.self, value: text)
    }
}

/// Count wording for status bars and subtitles (UC-COPY-09: thousands separators, plural).
enum StatusBarText {
    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted(.number)) \(n == 1 ? singular : plural)"
    }

    static func tracks(_ n: Int) -> String { count(n, "track", "tracks") }
    static func playlists(_ n: Int) -> String { count(n, "playlist", "playlists") }
    static func folders(_ n: Int) -> String { count(n, "folder", "folders") }
}
