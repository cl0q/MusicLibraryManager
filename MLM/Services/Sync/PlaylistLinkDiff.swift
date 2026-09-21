import Foundation

/// Summary of how a remote playlist's track list differs from a local
/// playlist's current tracks, used by the "Link Source" flow in
/// PlaylistDetailView.
///
/// Unlike `PlaylistSyncDiffer.computeNewEntries` (which returns the actual
/// unmatched entries), this only reports counts — the UI needs to know
/// *whether* there's a mismatch and *how big*, not the track details.
struct PlaylistLinkDiff: Equatable, Sendable {
    /// Remote tracks with no local match by any tier.
    let remoteOnly: Int
    /// Local tracks with no remote match by any tier.
    let localOnly: Int

    var hasDifferences: Bool { remoteOnly > 0 || localOnly > 0 }
}

/// Pure, no-IO diff computer for the link-source preview.
///
/// Reuses `PlaylistSyncDiffer.computeNewEntries` for both directions:
/// `remoteOnly` is the forward pass (remote entries not matched locally);
/// `localOnly` is the symmetric pass (local entries not matched remotely),
/// obtained by swapping the roles and wrapping each side in the other's
/// input shape.
enum PlaylistLinkDiffComputer {
    static func compute(
        remote: [PlaylistDifferRemoteEntry],
        local: [PlaylistDifferLocalTrack]
    ) -> PlaylistLinkDiff {
        // Forward: remote entries that don't match any local track.
        let remoteOnly = PlaylistSyncDiffer.computeNewEntries(
            remote: remote,
            local: local
        ).count

        // Symmetric: local entries that don't match any remote track.
        // Wrap each local track as a "remote" entry and each remote entry
        // as a "local" track so the same 3-tier matcher runs in reverse.
        let localAsRemote: [PlaylistDifferRemoteEntry] = local.map {
            PlaylistDifferRemoteEntry(
                externalID: $0.externalIDs.first ?? "",
                title: $0.title,
                artist: $0.artist,
                originalPath: $0.originalPath ?? ""
            )
        }
        let remoteAsLocal: [PlaylistDifferLocalTrack] = remote.enumerated().map { index, entry in
            PlaylistDifferLocalTrack(
                id: Int64(index),
                title: entry.title,
                artist: entry.artist,
                originalPath: entry.originalPath,
                externalIDs: [entry.externalID]
            )
        }
        let localOnly = PlaylistSyncDiffer.computeNewEntries(
            remote: localAsRemote,
            local: remoteAsLocal
        ).count

        return PlaylistLinkDiff(remoteOnly: remoteOnly, localOnly: localOnly)
    }
}
