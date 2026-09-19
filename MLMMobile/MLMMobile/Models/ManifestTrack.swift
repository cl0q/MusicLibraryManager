import Foundation

/// A single track entry in the library manifest (schema=1).
/// Field set matches IOS_SIDECAR_PLAN.md §3 exactly.
struct ManifestTrack: Codable, Identifiable, Equatable, Hashable {
    let uuid: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let duration: Int
    let path: String
    let energyBucket: Int
    let lufsI: Double

    var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid
        case title
        case artist
        case albumArtist = "album_artist"
        case album
        case duration
        case path
        case energyBucket = "energy_bucket"
        case lufsI = "lufs_i"
    }

    /// Formatted duration string (e.g., "4:14").
    var formattedDuration: String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
