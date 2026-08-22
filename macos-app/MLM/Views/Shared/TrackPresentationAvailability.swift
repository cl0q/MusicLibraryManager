import Foundation

/// Maps a fetched track batch to verified availability for table presentation.
enum TrackPresentationAvailability {
    static func map(
        tracks: [Track],
        libraryRoot: URL?,
        fileExists: (URL) -> Bool
    ) -> [Int64: TrackAvailability] {
        var availabilityByTrackID: [Int64: TrackAvailability] = [:]

        for track in tracks {
            guard let trackID = track.id else { continue }
            if let organizedPath = track.organizedPath,
               !organizedPath.isEmpty,
               !(organizedPath as NSString).isAbsolutePath,
               libraryRoot == nil {
                // The relative path is persisted as local, but cannot be
                // verified until the root snapshot arrives. Never flash an
                // unverified path as File missing.
                availabilityByTrackID[trackID] = .local
                continue
            }
            availabilityByTrackID[trackID] = track.availability(
                libraryRoot: libraryRoot,
                fileExists: fileExists
            )
        }

        return availabilityByTrackID
    }
}
