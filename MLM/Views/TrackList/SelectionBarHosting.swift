import Observation
import SwiftUI

// MARK: - Connecting a track table to the selection bar (W2-G)

/// What the selection bar acts on: the track table inside the same scaffold — its model
/// (selection and rows in display order), its configuration (the same `TrackListActions` as its
/// context menu) and its live state (drive, running downloads).
struct TrackSelectionBarSource {
    let model: TrackListModel
    let configuration: TrackListConfiguration
    let live: TrackTableLive
}

/// The link between the track table(s) inside one content scaffold and the selection bar in
/// that scaffold's `selectionBar:` slot. The table registers itself when it appears
/// (`TrackListTable` does this for every host); the bar reads the latest registration.
///
/// **Adopting the bar in a place that hosts a `TrackListTable` (album, genre, folder lists):**
/// ```swift
/// ContentScaffold(showsDriveBanner: true) {
///     MyTrackList()                    // hosts TrackListTable somewhere inside
/// } selectionBar: {
///     TrackSelectionBar()              // `.searchResults` in the search pane
/// }
/// .hostsTrackSelectionBar()
/// ```
/// Nothing else: the bar shows with ≥ 2 shown selected rows of that table while the place is
/// the visible one, and acts on them through the table's own actions.
@MainActor
@Observable
final class TrackSelectionBarChannel {
    /// The table the bar acts on; the one that registered last.
    private(set) var source: TrackSelectionBarSource?

    func register(_ source: TrackSelectionBarSource) {
        self.source = source
    }

    /// The table with `model` went away. A newer table that already registered stays.
    func unregister(_ model: TrackListModel) {
        if source?.model === model { source = nil }
    }
}

extension View {
    /// Gives the track tables inside and the `TrackSelectionBar` in the scaffold's
    /// `selectionBar:` slot one channel. Apply it to the `ContentScaffold`.
    func hostsTrackSelectionBar() -> some View {
        modifier(TrackSelectionBarHosting())
    }
}

private struct TrackSelectionBarHosting: ViewModifier {
    @State private var channel = TrackSelectionBarChannel()

    func body(content: Content) -> some View {
        content.environment(channel)
    }
}

/// Registers a track table with the selection bar of its scaffold, if the scaffold hosts one
/// (`TrackListTable` applies it). Runs on appear, on a change of the list's context (a renamed
/// playlist) and on disappear — never per selection change.
struct TrackSelectionBarRegistration: ViewModifier {
    let model: TrackListModel
    let configuration: TrackListConfiguration
    let live: TrackTableLive

    @Environment(TrackSelectionBarChannel.self) private var channel: TrackSelectionBarChannel?

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onChange(of: configuration.listContext) { _, _ in register() }
            .onDisappear { channel?.unregister(model) }
    }

    private func register() {
        channel?.register(TrackSelectionBarSource(model: model, configuration: configuration, live: live))
    }
}
