import AppKit
import SwiftUI

// MARK: - Playback pieces that belong to the window, not to the toolbar item

/// Attached once to the main window's content (W2-C review): the toolbar player can move into
/// the toolbar's overflow menu (UC-TB-03), and whatever lives inside it then disappears.
/// - Esc ends a running preview from anywhere in the window (`PreviewEscapeKey`).
/// - Playback's status-bar notes (skips, refusals, failures) reach this window's status bar.
/// - The one Locate File… panel.
struct PlaybackWindowSupport: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(PreviewEscapeKey())
            .background {
                PlaybackWindowHost()
            }
    }
}

extension View {
    /// See `PlaybackWindowSupport`.
    func playbackWindowSupport() -> some View {
        modifier(PlaybackWindowSupport())
    }
}

/// A zero-size leaf (position ticks never reach the window content).
private struct PlaybackWindowHost: View {
    @Environment(\.container) private var container

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .background {
                if let playback = container.playbackViewModel {
                    PlayerNoticeRelay(viewModel: playback)
                }
            }
            .locateFilePanel()
    }
}

/// Shows the player's notes in this window's status bar, each with its one action
/// (UC-STATUS-04/05/07).
struct PlayerNoticeRelay: View {
    let viewModel: PlaybackViewModel
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: viewModel.notice?.id) { _, _ in
                guard let notice = viewModel.notice else { return }
                statusBar?.post(notice.text, actions: notice.action.map { [statusAction($0)] } ?? [])
            }
    }

    private func statusAction(_ action: PlaybackNotice.Action) -> StatusAction {
        switch action {
        case .download(let tracks):
            StatusAction("Download") { TrackCommandActions.download(tracks) }
        case .locate(let track):
            StatusAction("Locate…") { LocateFileRequest.shared.begin(track) }
        case .showInFinder(let url):
            StatusAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .tryAgain(let track):
            StatusAction("Try Again") { [viewModel] in Task { await viewModel.playTrack(track) } }
        }
    }
}
