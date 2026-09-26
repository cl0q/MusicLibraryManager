import Foundation
import Testing
@testable import MLM

@Suite("LOGIC-025 DAB stream URL validation")
struct DabStreamURLValidationTests {

    @Test func malformedProviderURLIsClassifiedAndFallsThrough() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dab = InvalidURLDAB()
        let squid = NoResultSquid()
        let youtube = SuccessfulYouTube()
        let orchestrator = DownloadOrchestrator(
            libraryRoot: root.path,
            soundCloudDownloader: UnavailableSoundCloud(),
            youtubeDownloader: youtube,
            dabClient: dab,
            squidClient: squid,
            clock: ImmediateClock()
        )
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 25,
            artist: "Artist",
            title: "Title",
            query: "Artist - Title",
            soundcloudURL: nil,
            userId: nil
        )

        let result = await orchestrator.downloadBatch([request])

        #expect(result.succeeded == 1)
        #expect(dab.downloadCallCount == 1)
        #expect(squid.searchCallCount == 1)
        #expect(youtube.searchCallCount == 1)
    }

    @Test func malformedURLFixtureIsRejectedByFoundation() {
        // The actual DAB client owns a private URLSession and does not expose
        // a response-injection seam. This fixture is therefore paired with
        // the classified-fallback integration test above.
        let malformedProviderURL = "http://[::1"
        #expect(URL(string: malformedProviderURL) == nil)

        let error = DABError.invalidStreamURL(malformedProviderURL)
        guard case .invalidStreamURL(let rejectedURL) = error else {
            Issue.record("Expected invalidStreamURL")
            return
        }
        #expect(rejectedURL == malformedProviderURL)
    }

    private struct ImmediateClock: DownloadOrchestrator.DownloaderClock {
        func sleep(_ seconds: Double) async {}
    }

    private final class UnavailableSoundCloud: DownloadOrchestrator.SoundCloudProviding, @unchecked Sendable {
        let isAvailable = false

        func download(
            trackURL: String,
            outputDir: URL,
            trackId: Int64,
            title: String,
            onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome {
            Issue.record("Unavailable SoundCloud must not be called")
            throw CancellationError()
        }
    }

    private final class InvalidURLDAB: DownloadOrchestrator.DABProviding, @unchecked Sendable {
        private let track: DabTrack = {
            let json = """
                {
                    "id": 25,
                    "title": "Title",
                    "artist": "Artist",
                    "album_title": "Album",
                    "album_id": 1,
                    "duration": 200,
                    "audio_quality": null
                }
                """.data(using: .utf8)!
            return try! JSONDecoder().decode(DabTrack.self, from: json)
        }()

        private(set) var downloadCallCount = 0

        func searchTrack(query: String) async throws -> DabTrack? {
            track
        }

        func matches(dabTrack: DabTrack, artist: String, title: String) -> Bool {
            true
        }

        func download(
            dabTrack: DabTrack,
            outputDir: URL,
            artist: String,
            title: String
        ) async throws -> DABClient.DownloadResult {
            downloadCallCount += 1
            throw DABError.invalidStreamURL("http://[::1")
        }
    }

    private final class NoResultSquid: DownloadOrchestrator.SquidProviding, @unchecked Sendable {
        private(set) var searchCallCount = 0

        func searchTrack(query: String, artist: String, title: String) async throws -> SquidTrack? {
            searchCallCount += 1
            return nil
        }

        func download(
            track: SquidTrack,
            outputDir: URL,
            artist: String,
            title: String
        ) async throws -> SquidWtfClient.DownloadResult {
            Issue.record("Squid download must not be called when search has no result")
            return .notFound
        }
    }

    private final class SuccessfulYouTube: DownloadOrchestrator.YouTubeProviding, @unchecked Sendable {
        let isAvailable = true
        private(set) var searchCallCount = 0

        func searchAndDownload(
            query: String,
            outputDir: URL,
            onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome {
            searchCallCount += 1
            let file = outputDir.appendingPathComponent("fallback.m4a")
            try Data("test audio".utf8).write(to: file)
            return .success(file)
        }

        func downloadByURL(_ url: String, outputDir: URL) async throws -> DownloadOutcome {
            Issue.record("The test request has no YouTube URL")
            throw CancellationError()
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DabStreamURLValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
