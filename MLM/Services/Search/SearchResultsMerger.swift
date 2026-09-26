import Foundation

/// Pure, Sendable merger that orders search results:
/// context tracks first (preserving their order), then library tracks,
/// then remote tracks, deduplicating by Track.id.
struct SearchResultsMerger: Sendable {
    enum Context: Equatable {
        case library
        case playlist(Int64)
        case other
    }

    static func merge(
        contextTracks: [Track],
        libraryTracks: [Track],
        remoteTracks: [Track]
    ) -> [Track] {
        var seen = Set<Int64>()
        var result: [Track] = []

        for track in contextTracks {
            if let id = track.id, !seen.contains(id) {
                seen.insert(id)
                result.append(track)
            } else if track.id == nil {
                result.append(track)
            }
        }

        for track in libraryTracks {
            if let id = track.id, !seen.contains(id) {
                seen.insert(id)
                result.append(track)
            } else if track.id == nil {
                result.append(track)
            }
        }

        for track in remoteTracks {
            if let id = track.id, !seen.contains(id) {
                seen.insert(id)
                result.append(track)
            } else if track.id == nil {
                result.append(track)
            }
        }

        return result
    }
}
