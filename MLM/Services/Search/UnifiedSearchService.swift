import Foundation

final class UnifiedSearchService: Sendable {
    /// Global shared instance of the queue service with lazy/fallback dependencies.
    static var shared: UnifiedSearchService!
    
    let dabClient: DABClient
    let squidClient: SquidWtfClient
    let soundCloudClient: SoundCloudClient
    let youtubeDownloader: YouTubeDownloader
    
    init(
        dabClient: DABClient,
        squidClient: SquidWtfClient,
        soundCloudClient: SoundCloudClient,
        youtubeDownloader: YouTubeDownloader
    ) {
        self.dabClient = dabClient
        self.squidClient = squidClient
        self.soundCloudClient = soundCloudClient
        self.youtubeDownloader = youtubeDownloader
    }
    
    func search(query: String, limit: Int = 3) async -> UnifiedSearchResults {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: [])
        }
        
        return await withTaskGroup(of: SearchResultTaskResult.self) { group in
            // 1. DABmusic search
            group.addTask {
                do {
                    let tracks = try await self.dabClient.searchTracks(query: query, limit: limit)
                    return .dab(tracks)
                } catch {
                    AppLogger.shared.log("UnifiedSearch: DAB search failed: \(error.localizedDescription)", level: .warning, source: "Search")
                    return .dab([])
                }
            }
            
            // 2. Qobuz search
            group.addTask {
                do {
                    let tracks = try await self.squidClient.searchTracks(query: query, limit: limit)
                    return .squid(tracks)
                } catch {
                    AppLogger.shared.log("UnifiedSearch: Qobuz search failed: \(error.localizedDescription)", level: .warning, source: "Search")
                    return .squid([])
                }
            }
            
            // 3. SoundCloud search
            group.addTask {
                do {
                    let tracks = try await self.soundCloudClient.searchTracks(query: query, limit: limit)
                    return .soundCloud(tracks)
                } catch {
                    AppLogger.shared.log("UnifiedSearch: SoundCloud search failed: \(error.localizedDescription)", level: .warning, source: "Search")
                    return .soundCloud([])
                }
            }
            
            // 4. YouTube search
            group.addTask {
                do {
                    let tracks = try await self.youtubeDownloader.searchTracks(query: query, limit: limit)
                    return .youtube(tracks)
                } catch {
                    AppLogger.shared.log("UnifiedSearch: YouTube search failed: \(error.localizedDescription)", level: .warning, source: "Search")
                    return .youtube([])
                }
            }
            
            var dabTracks: [DabTrack] = []
            var squidTracks: [SquidWtfClient.SquidTrack] = []
            var soundCloudTracks: [SoundCloudTrack] = []
            var youtubeTracks: [YouTubeTrack] = []
            
            for await result in group {
                switch result {
                case .dab(let tracks):
                    dabTracks = tracks
                case .squid(let tracks):
                    squidTracks = tracks
                case .soundCloud(let tracks):
                    soundCloudTracks = tracks
                case .youtube(let tracks):
                    youtubeTracks = tracks
                }
            }
            
            return UnifiedSearchResults(
                dabTracks: dabTracks,
                squidTracks: squidTracks,
                soundCloudTracks: soundCloudTracks,
                youtubeTracks: youtubeTracks
            )
        }
    }
    
    // MARK: - Audio streaming resolver helpers
    func resolvePreviewURL(forDab track: DabTrack) async -> URL? {
        if let streamStr = try? await dabClient.getStreamURL(trackId: track.id),
           let url = URL(string: streamStr) {
            return url
        }
        return nil
    }
    
    func resolvePreviewURL(forSquid track: SquidWtfClient.SquidTrack) async -> URL? {
        if let url = try? await squidClient.getStreamURL(trackId: track.id) {
            return url
        }
        return nil
    }
    
    func resolvePreviewURL(forSoundCloud track: SoundCloudTrack) async -> URL? {
        if let clientId = SoundCloudCredentials.clientId(), !clientId.isEmpty {
            let streamStr = "https://api-v2.soundcloud.com/tracks/\(track.id)/stream?client_id=\(clientId)"
            if let url = URL(string: streamStr) {
                return url
            }
        }
        if let permalink = track.permalinkUrl, let url = URL(string: permalink) {
            return url
        }
        return nil
    }
    
    func resolvePreviewURL(forYouTube track: YouTubeTrack) async -> URL? {
        if let ytdlp = ProcessRunner.findExecutable("yt-dlp") {
            let args = ["-g", "-f", "bestaudio", track.watchUrl]
            if let runResult = try? await ProcessRunner.run(ytdlp, arguments: args),
               runResult.isSuccess {
                let clean = runResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: clean) {
                    return url
                }
            }
        }
        return nil
    }
    
    private enum SearchResultTaskResult {
        case dab([DabTrack])
        case squid([SquidWtfClient.SquidTrack])
        case soundCloud([SoundCloudTrack])
        case youtube([YouTubeTrack])
    }
}

struct UnifiedSearchResults: Sendable {
    let dabTracks: [DabTrack]
    let squidTracks: [SquidWtfClient.SquidTrack]
    let soundCloudTracks: [SoundCloudTrack]
    let youtubeTracks: [YouTubeTrack]
}
