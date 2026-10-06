import SwiftUI

/// `Preview` / `Stop` for a suggestion or result that isn't in the library (IMP-109): it plays in
/// the toolbar player's Preview state (`Resolving…` while its SoundCloud or YouTube link is
/// looked up), never downloads into the library and never replaces what is playing for good —
/// Esc or `Stop` brings the main track back. Rows without such a link show nothing.
enum StreamPreviewControl {
    /// The row that owns a preview (its `Stop` shows while it runs).
    static func owner(_ id: String) -> PreviewOwner { "stream:\(id)" }

    /// Starts the preview of `candidate`, ends it when this row's is running, and switches from
    /// another row's preview to this one.
    @MainActor
    static func toggle(_ candidate: PreviewCandidate, owner: PreviewOwner, playback: PlaybackViewModel) {
        let preview = playback.preview
        if preview.isActive, preview.owner != owner { preview.end() }
        preview.toggle(owner: owner, candidate: candidate)
    }

    @MainActor
    static func isRunning(owner: PreviewOwner, playback: PlaybackViewModel) -> Bool {
        let preview = playback.preview
        return preview.isActive && preview.owner == owner
    }
}

/// The row button.
struct StreamPreviewButton: View {
    let link: String?
    let title: String
    let rowID: String

    @Environment(\.container) private var container

    var body: some View {
        if let candidate = StreamLink.candidate(link: link, title: title), let playback = container.playbackViewModel {
            let owner = StreamPreviewControl.owner(rowID)
            let running = StreamPreviewControl.isRunning(owner: owner, playback: playback)
            Button(running ? "Stop" : "Preview") {
                StreamPreviewControl.toggle(candidate, owner: owner, playback: playback)
            }
            .help(running ? "Stops the preview" : "Plays a stream in the toolbar player without downloading it")
            .onDisappear { playback.preview.ownerGone(owner) }
        }
    }
}

/// The row's context-menu item (no key equivalent: Space is never a menu shortcut).
struct StreamPreviewMenuItem: View {
    let link: String?
    let title: String
    let rowID: String

    @Environment(\.container) private var container

    var body: some View {
        if let candidate = StreamLink.candidate(link: link, title: title), let playback = container.playbackViewModel {
            let owner = StreamPreviewControl.owner(rowID)
            Button(StreamPreviewControl.isRunning(owner: owner, playback: playback) ? "Stop Preview" : "Preview") {
                StreamPreviewControl.toggle(candidate, owner: owner, playback: playback)
            }
        }
    }
}
