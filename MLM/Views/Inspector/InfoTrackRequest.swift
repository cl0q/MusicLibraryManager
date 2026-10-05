import Observation

/// An explicit `Show Details` for a track that isn't selected in a track list (a failed sync
/// row): Info shows that track until the track-list selection changes. The track-list
/// selection itself (`InspectedTrackSelection`) is never written here.
@MainActor
@Observable
final class InfoTrackRequest {
    static let shared = InfoTrackRequest()

    /// The requested tracks, while the selection is still the one they were requested over.
    private(set) var trackIDs: [Int64]?
    @ObservationIgnored private var baseline: [Int64] = []

    func show(_ ids: [Int64], over selection: [Int64]) {
        trackIDs = ids
        baseline = selection
    }

    /// Another library opened.
    func clear() {
        trackIDs = nil
        baseline = []
    }

    /// The selection changed: the request is over.
    func selectionDidChange(_ selection: [Int64]) {
        guard trackIDs != nil, selection != baseline else { return }
        trackIDs = nil
    }

    /// What Info shows for `selection`.
    func effectiveSelection(_ selection: [Int64]) -> [Int64] {
        guard let trackIDs, selection == baseline else { return selection }
        return trackIDs
    }
}
