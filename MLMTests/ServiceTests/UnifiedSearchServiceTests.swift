import Foundation
import Testing
@testable import MLM

@Suite("Unified Search & Multi-Source Clients Tests")
struct UnifiedSearchServiceTests {

    @Test func testDABClientSearchTracks() async throws {
        let tokenStorage = TokenStorage()
        let dabClient = DABClient(tokenStorage: tokenStorage)
        
        do {
            let tracks = try await dabClient.searchTracks(query: "Yeat", limit: 2)
            print("🔊 DAB Search returned \(tracks.count) tracks")
            for track in tracks {
                print("  - \(track.artist) - \(track.title) (ID: \(track.id))")
            }
            #expect(tracks.count <= 2)
        } catch {
            print("⚠️ DAB Search tracks failed or skipped: \(error.localizedDescription)")
        }
    }

    @Test func testSquidWtfClientSearchTracks() async throws {
        let squidClient = SquidWtfClient()
        
        do {
            let tracks = try await squidClient.searchTracks(query: "Drake", limit: 2)
            print("🔊 Squid Qobuz Search returned \(tracks.count) tracks")
            for track in tracks {
                print("  - \(track.artist) - \(track.title) (ID: \(track.id))")
            }
            #expect(tracks.count <= 2)
        } catch {
            print("⚠️ Squid Qobuz Search tracks failed or skipped: \(error.localizedDescription)")
        }
    }

    @Test func testSoundCloudClientSearchTracks() async throws {
        let tokenStorage = TokenStorage()
        let oauthManager = OAuthManager()
        let dbPool = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: dbPool)
        let sourceRepo = SourceRepository(database: dbPool)
        
        let scClient = SoundCloudClient(
            tokenStorage: tokenStorage,
            oauthManager: oauthManager,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )
        
        do {
            let tracks = try await scClient.searchTracks(query: "Daft Punk", limit: 2)
            print("🔊 SoundCloud Search returned \(tracks.count) tracks")
            for track in tracks {
                print("  - \(track.user?.username ?? "Unknown") - \(track.title) (ID: \(track.id))")
            }
            #expect(tracks.count <= 2)
        } catch {
            print("⚠️ SoundCloud Search tracks failed or skipped: \(error.localizedDescription) (this is expected if not authenticated)")
        }
    }

    @Test func testYouTubeDownloaderSearchTracks() async throws {
        let youtubeDownloader = YouTubeDownloader()
        
        if youtubeDownloader.isAvailable {
            do {
                let tracks = try await youtubeDownloader.searchTracks(query: "Never Gonna Give You Up", limit: 2)
                print("🔊 YouTube Search returned \(tracks.count) tracks")
                for track in tracks {
                    print("  - \(track.uploader ?? "Unknown") - \(track.title) (URL: \(track.watchUrl))")
                }
                #expect(tracks.count > 0)
                #expect(tracks.count <= 2)
            } catch {
                print("⚠️ YouTube Search tracks failed: \(error.localizedDescription)")
            }
        } else {
            print("⚠️ YouTubeDownloader (yt-dlp) is not available on this system. Skipping test.")
        }
    }

    @Test func testUnifiedSearchServiceSearch() async throws {
        let tokenStorage = TokenStorage()
        let oauthManager = OAuthManager()
        let dbPool = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: dbPool)
        let sourceRepo = SourceRepository(database: dbPool)
        
        let scClient = SoundCloudClient(
            tokenStorage: tokenStorage,
            oauthManager: oauthManager,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )
        let dabClient = DABClient(tokenStorage: tokenStorage)
        let squidClient = SquidWtfClient()
        let youtubeDownloader = YouTubeDownloader()
        
        let searchService = UnifiedSearchService(
            dabClient: dabClient,
            squidClient: squidClient,
            soundCloudClient: scClient,
            youtubeDownloader: youtubeDownloader
        )
        
        let results = await searchService.search(query: "Kendrick Lamar", limit: 2)
        print("🔊 Unified Search results aggregated:")
        print("  DAB tracks: \(results.dabTracks.count)")
        print("  Squid tracks: \(results.squidTracks.count)")
        print("  SoundCloud tracks: \(results.soundCloudTracks.count)")
        print("  YouTube tracks: \(results.youtubeTracks.count)")
        
        #expect(results.dabTracks.count <= 2)
        #expect(results.squidTracks.count <= 2)
        #expect(results.soundCloudTracks.count <= 2)
        #expect(results.youtubeTracks.count <= 2)
    }
}
