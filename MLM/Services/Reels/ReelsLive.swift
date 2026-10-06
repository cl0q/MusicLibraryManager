import Foundation

/// The app's wiring of `ReelsModel`: the repository, the search and download services, the
/// playlist edits and the `yt-dlp` fetcher.
@MainActor
enum ReelsLive {
    /// `nil` before a library is open.
    static func dependencies(_ container: DependencyContainer, shell: ShellActions?) -> ReelsModel.Dependencies? {
        guard let repository = container.reelRepository else { return nil }
        let search: any ReelSearching
        if let service = container.unifiedSearchService {
            search = LiveReelSearch(service: service)
        } else {
            search = LiveReelSearch(run: { _ in UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: []) })
        }
        var dependencies = ReelsModel.Dependencies(
            repository: repository,
            analyzer: LiveReelAnalyzer(),
            audio: ShazamReelAudioIdentifier(),
            search: search,
            fetcher: YtDlpReelFetcher(),
            downloader: LiveReelResultDownloader(container: container))
        dependencies.addToPlaylist = { trackID, playlistID in
            await shell?.edits.addTracks([trackID], toPlaylist: playlistID)
        }
        dependencies.newPlaylist = { trackID in
            _ = await shell?.edits.newPlaylist(named: nil, fromTrackIDs: [trackID])
        }
        dependencies.postChange = {
            NotificationCenter.default.post(name: .reelsDidChange, object: nil)
        }
        return dependencies
    }
}

/// A result becomes a normal library track — **no album** (DEC-013; today's `Reels` album is
/// gone) — and its download goes through the existing pipeline as an Activity operation.
@MainActor
struct LiveReelResultDownloader: ReelResultDownloading {
    let container: DependencyContainer

    func start(_ result: ReelSearchResult) async -> ReelDownloadStart {
        switch result.source {
        case .soundCloud, .youtube, .dab:
            guard let service = SearchDownloadService.live(container) else { return .failed("no library is open") }
            let source: RemoteSearchResult.Source = switch result.source {
            case .soundCloud: .soundcloud
            case .youtube: .youtube
            default: .dab
            }
            let remote = RemoteSearchResult(
                id: result.id, source: source, artist: result.artist, title: result.title,
                durationSeconds: result.durationSeconds, externalId: result.externalID, sourceURL: result.sourceURL)
            switch await service.download(remote) {
            case .started(let trackID, _): return .started(trackID: trackID)
            case .alreadyInLibrary(let trackID): return .alreadyInLibrary(trackID: trackID)
            case .busy: return .failed(TrackCommandState.downloadBusyReason)
            case .failed(let cause): return .failed(cause)
            }
        case .qobuz:
            guard let sources = container.sourceRepository else { return .failed("no library is open") }
            var track = Track(artist: result.artist, album: "", title: result.title, format: "qobuz",
                              originalPath: "qobuz://\(result.externalID)")
            track.duration = result.durationSeconds
            do {
                guard let canonical = try await sources.materializeRemoteTrack(track, sourceName: "qobuz", externalId: result.externalID),
                      let trackID = canonical.id else { return .failed("the result has no source identity") }
                guard canonical.isRemote else { return .alreadyInLibrary(trackID: trackID) }
                LiveTrackDownloadStarter(container: container).start(canonical, preferredSource: .auto, artworkURL: nil)
                return .started(trackID: trackID)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func progress(of trackID: Int64) async -> ReelResultDownload {
        guard let track = (try? await container.trackRepository?.fetchTrack(id: trackID)) ?? nil else { return .queued }
        if track.isLocal { return .inLibrary }
        if let echo = ActivityCenter.shared.echo(for: .tracks([trackID])), echo.state == .running || echo.state == .queued {
            return echo.state == .running ? .downloading : .queued
        }
        if let failure = track.downloadFailureRecord {
            return .failed(DownloadFailureReasonText.plain(failure.reason, sourceHint: DownloadFailureReasonText.sourceHint(for: track)))
        }
        return .queued
    }
}
