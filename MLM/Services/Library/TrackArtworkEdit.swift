import Foundation

/// `Set Artwork` (D-TD-ARTWORK-IN, UC-UNDO-07): an image dropped on the Info cover becomes the
/// artwork of every selected track — one undo step. The image goes into the artwork cache the
/// track covers read (`<id>_1200.jpg` / `<id>_500.jpg`) and the track's `artwork` row points at it
/// (`source = 'user'`). The audio files are not rewritten. Undo puts the earlier files and row
/// back exactly (or removes them when there were none).
@MainActor
struct TrackArtworkEdit {
    /// What one track had before: its row and the bytes of both cache files.
    struct Previous: Sendable {
        let row: Artwork?
        let large: Data?
        let small: Data?
    }

    /// The step's value: what each track had, and the new bytes for a redo.
    struct Done: Sendable {
        let previous: [Int64: Previous]
        let image: Data
    }

    static let actionName = "Set Artwork"

    let analysis: AnalysisRepository?
    let cacheDirectory: URL
    let undo: UndoCenter
    var notificationCenter: NotificationCenter = .default

    /// The cache the track covers read (the same folder `ArtworkBackfillService` writes).
    static var standardCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mlm.artwork_cache")
    }

    /// The status sentence of a finished step.
    static func message(title: String?, count: Int) -> String {
        if count == 1, let title { return "Set the artwork of “\(title)”" }
        return "Set the artwork of \(StatusBarText.tracks(count))"
    }

    /// Sets the artwork of `trackIDs`. Returns the refusal sentence when the image can't be used
    /// (nothing is written then), nil otherwise — a failure of the write itself is reported by
    /// the undo center in the status bar.
    func set(_ source: CoverSource, trackIDs: [Int64], title: String? = nil) async -> String? {
        let ids = Array(Set(trackIDs)).sorted()
        guard !ids.isEmpty, let analysis else { return nil }
        let data: Data
        switch source {
        case .file(let url):
            guard let bytes = try? Data(contentsOf: url), AlbumCoverFiles.isImage(bytes) else {
                return DropWords.notACover(fileName: url.lastPathComponent)
            }
            data = bytes
        case .data(let bytes):
            guard AlbumCoverFiles.isImage(bytes) else { return DropWords.notACover(fileName: nil) }
            data = bytes
        }
        let service = ArtworkService(cacheDir: cacheDirectory)
        let center = notificationCenter
        do {
            _ = try await undo.perform(
                Self.actionName,
                failure: "Couldn’t set the artwork of \(StatusBarText.tracks(ids.count))",
                do: { () async throws -> Done? in
                    var previous: [Int64: Previous] = [:]
                    for id in ids {
                        previous[id] = Previous(
                            row: try await analysis.fetchArtwork(trackId: id),
                            large: try? Data(contentsOf: service.cachedPath(trackId: id, size: .large)),
                            small: try? Data(contentsOf: service.cachedPath(trackId: id, size: .small)))
                    }
                    try await Self.apply(data, to: ids, service: service, analysis: analysis, center: center)
                    return Done(previous: previous, image: data)
                },
                undo: { done in
                    for (id, before) in done.previous { try await Self.restore(before, id: id, service: service, analysis: analysis) }
                    Self.announce(Array(done.previous.keys), center: center)
                    return done
                },
                redo: { done in
                    try await Self.apply(done.image, to: Array(done.previous.keys), service: service, analysis: analysis, center: center)
                    return done
                },
                message: { _ in Self.message(title: title, count: ids.count) }
            )
        } catch {
            // Reported in the status bar by the center.
        }
        return nil
    }

    private static func apply(_ data: Data, to ids: [Int64], service: ArtworkService,
                              analysis: AnalysisRepository, center: NotificationCenter) async throws {
        for id in ids {
            try service.saveResized(data: data, trackId: id)
            try await analysis.saveArtwork(Artwork(
                trackId: id, artworkPath: service.cachedPath(trackId: id, size: .large).path, source: "user",
                musicbrainzReleaseGroupId: nil, resolution: nil,
                fetchedAt: ISO8601DateFormatter().string(from: Date())))
        }
        announce(ids, center: center)
    }

    private static func restore(_ before: Previous, id: Int64, service: ArtworkService, analysis: AnalysisRepository) async throws {
        let fm = FileManager.default
        let largeURL = service.cachedPath(trackId: id, size: .large)
        let smallURL = service.cachedPath(trackId: id, size: .small)
        if let large = before.large { try large.write(to: largeURL, options: .atomic) } else { try? fm.removeItem(at: largeURL) }
        if let small = before.small { try small.write(to: smallURL, options: .atomic) } else { try? fm.removeItem(at: smallURL) }
        if let row = before.row {
            try await analysis.replaceArtwork(row)
        } else {
            try await analysis.deleteArtwork(trackIds: [id])
        }
    }

    private static func announce(_ ids: [Int64], center: NotificationCenter) {
        for id in ids {
            TrackArtworkCache.shared.invalidate(forTrackId: id)
            center.post(name: .trackArtworkDidChange, object: nil, userInfo: ["trackId": id])
        }
    }
}
