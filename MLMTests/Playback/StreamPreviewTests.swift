import Foundation
import Testing
@testable import MLM

/// Stream preview (IMP-109): links, the two resolvers, the machine, the player's words, and the
/// whole thing through the real view model with fake resolver, fetcher and players. No network,
/// no process, no audio device.
@Suite("StreamPreviewTests")
@MainActor
struct StreamPreviewTests {

    // MARK: Links

    @Test func onlySoundCloudAndYouTubeLinksAreResolved() {
        func kind(_ text: String) -> StreamLink? { URL(string: text).flatMap(StreamLink.kind(of:)) }
        #expect(kind("https://soundcloud.com/overmono/so-u-kno") == .soundCloud)
        #expect(kind("https://m.soundcloud.com/overmono/so-u-kno") == .soundCloud)
        #expect(kind("https://www.youtube.com/watch?v=abc") == .youTube)
        #expect(kind("https://music.youtube.com/watch?v=abc") == .youTube)
        #expect(kind("https://youtu.be/abc") == .youTube)
        #expect(kind("https://example.com/soundcloud.com") == nil)
        #expect(kind("https://notsoundcloud.com/x") == nil)
        #expect(kind("https://dab.yeet.su/track/1") == nil)
        #expect(kind("ftp://soundcloud.com/x") == nil)
        #expect(StreamLink.candidate(link: nil, title: "T") == nil)
        #expect(StreamLink.candidate(link: "https://qobuz.com/x", title: "T") == nil)
        #expect(StreamLink.candidate(link: " https://youtu.be/abc ", title: "T")
                == .stream(URL(string: "https://youtu.be/abc")!, title: "T"))
    }

    // MARK: yt-dlp

    private func result(_ stdout: String = "", stderr: String = "", exit: Int32 = 0, timedOut: Bool = false) -> ProcessRunner.ProcessResult {
        ProcessRunner.ProcessResult(exitCode: exit, stdout: stdout, stderr: stderr, timedOut: timedOut, processIdentifier: 0)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, [String], TimeInterval)] = []
        var all: [(String, [String], TimeInterval)] { lock.withLock { stored } }
        func add(_ call: (String, [String], TimeInterval)) { lock.withLock { stored.append(call) } }
    }

    private func ytdlp(_ answer: ProcessRunner.ProcessResult, tool: String? = "/bin/yt-dlp", calls: Calls = Calls()) -> YtDlpStreamResolver {
        YtDlpStreamResolver(executable: { tool }, run: { path, arguments, timeout in
            calls.add((path, arguments, timeout))
            return answer
        })
    }

    @Test func ytDlpIsAskedForTheDirectAudioUrlWithATenSecondTimeout() async throws {
        let calls = Calls()
        let page = URL(string: "https://www.youtube.com/watch?v=abc")!
        let url = try await ytdlp(result("https://rr1.googlevideo.com/audio.m4a\n"), calls: calls).resolve(page)
        #expect(url.absoluteString == "https://rr1.googlevideo.com/audio.m4a")
        let call = try #require(calls.all.first)
        #expect(call.0 == "/bin/yt-dlp")
        #expect(call.1 == ["--no-playlist", "-g", "-f", "bestaudio[ext=m4a]/bestaudio", page.absoluteString])
        #expect(call.2 == 10)
    }

    @Test func ytDlpFailuresAreSaidInWords() async {
        let page = URL(string: "https://youtu.be/abc")!
        await #expect(throws: StreamResolveError.toolMissing) { try await ytdlp(result(), tool: nil).resolve(page) }
        await #expect(throws: StreamResolveError.timedOut) { try await ytdlp(result(exit: 15, timedOut: true)).resolve(page) }
        await #expect(throws: StreamResolveError.noStream) { try await ytdlp(result("not a url\n")).resolve(page) }
        await #expect(throws: StreamResolveError.failed("Video unavailable")) {
            try await ytdlp(result(stderr: "WARNING: x\nERROR: [youtube] abc: Video unavailable\n", exit: 1)).resolve(page)
        }
        await #expect(throws: StreamResolveError.failed("yt-dlp couldn’t resolve it")) {
            try await ytdlp(result(stderr: "", exit: 1)).resolve(page)
        }
    }

    @Test func theResolverDispatchesByLinkAndRefusesTheRest() async throws {
        let resolver = StreamResolver(
            soundCloud: { _ in URL(string: "https://cf-media.sndcdn.com/a.mp3")! },
            youTube: { _ in URL(string: "https://rr1.googlevideo.com/a.m4a")! })
        #expect(try await resolver.resolve(URL(string: "https://soundcloud.com/a/b")!).host == "cf-media.sndcdn.com")
        #expect(try await resolver.resolve(URL(string: "https://youtu.be/x")!).host == "rr1.googlevideo.com")
        await #expect(throws: StreamResolveError.unsupportedLink) { try await resolver.resolve(URL(string: "https://dab.yeet.su/1")!) }
    }

    // MARK: SoundCloud client

    private final class Store: SoundCloudTokenStoring, @unchecked Sendable {
        let signedIn: Bool
        init(signedIn: Bool = true) { self.signedIn = signedIn }
        func getCredentials(service: TokenStorage.Service) throws -> TokenStorage.Credentials? {
            signedIn ? TokenStorage.Credentials(accessToken: "token", refreshToken: nil, expiryDate: nil) : nil
        }
        func saveTokens(service: TokenStorage.Service, accessToken: String, refreshToken: String?, expiresIn: Int?) throws {}
        func updateAccessToken(service: TokenStorage.Service, accessToken: String, expiresIn: Int) throws {}
        func deleteCredentials(service: TokenStorage.Service) throws {}
    }

    /// Answers `/resolve` with a track and the stream request with a redirect's final address.
    private final class Http: SoundCloudHTTPRequesting, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        let streamURL: String?
        let streamStatus: Int
        init(streamURL: String? = "https://api.soundcloud.com/tracks/9/stream", streamStatus: Int = 206) {
            self.streamURL = streamURL
            self.streamStatus = streamStatus
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { seen.append(request) }
            let url = request.url!
            if url.path.hasSuffix("/resolve") {
                let stream = streamURL.map { "\"\($0)\"" } ?? "null"
                let json = """
                {"id":9,"title":"So U Kno","duration":180000,"genre":null,"permalink_url":"https://soundcloud.com/o/s",
                 "stream_url":\(stream),"artwork_url":null,"created_at":"2026/07/21 08:00:00 +0000",
                 "user":{"id":1,"username":"o","avatar_url":null,"full_name":null,"permalink":"o"}}
                """
                return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            // The redirect's final address (what `URLSession` reports as the response URL).
            let final = URL(string: "https://cf-media.sndcdn.com/9.128.mp3?sig=1")!
            return (Data([0]), HTTPURLResponse(url: final, statusCode: streamStatus, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func client(_ http: Http, signedIn: Bool = true) throws -> SoundCloudClient {
        let database = try DatabaseManager.inMemory()
        return SoundCloudClient(
            tokenStorage: Store(signedIn: signedIn), oauthManager: OAuthManager(),
            trackRepository: TrackRepository(database: database), sourceRepository: SourceRepository(database: database),
            clientId: "id", clientSecret: "secret", http: http)
    }

    @Test func soundCloudGivesTheRedirectsFinalAddressFromOneByteOnly() async throws {
        let http = Http()
        let url = try await client(http).previewStreamURL(trackURL: "https://soundcloud.com/o/s")
        #expect(url.absoluteString == "https://cf-media.sndcdn.com/9.128.mp3?sig=1")
        let stream = try #require(http.requests.last)
        #expect(stream.value(forHTTPHeaderField: "Range") == "bytes=0-0", "nothing is downloaded")
        #expect(stream.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func soundCloudWithoutAStreamOrAccountSaysSo() async throws {
        await #expect(throws: StreamResolveError.noStream) {
            try await client(Http(streamURL: nil)).previewStreamURL(trackURL: "https://soundcloud.com/o/s")
        }
        await #expect(throws: StreamResolveError.noStream) {
            try await client(Http(streamURL: "https://evil.example.com/stream")).previewStreamURL(trackURL: "https://soundcloud.com/o/s")
        }
        await #expect(throws: StreamResolveError.noStream) {
            try await client(Http(streamStatus: 403)).previewStreamURL(trackURL: "https://soundcloud.com/o/s")
        }
        await #expect(throws: StreamResolveError.notSignedIn) {
            try await client(Http(), signedIn: false).previewStreamURL(trackURL: "https://soundcloud.com/o/s")
        }
    }

    // MARK: Machine

    private let page = URL(string: "https://soundcloud.com/o/s")!

    @Test func aStreamCandidateStartsASessionWithAStandInTrack() {
        var machine = PreviewMachine()
        let effects = machine.toggle(owner: "row", candidate: .stream(page, title: "So U Kno"), main: .nothing)
        guard case .resolve(let track, _)? = effects.first(where: { if case .resolve = $0 { return true } else { return false } }) else {
            Issue.record("no resolve effect"); return
        }
        #expect(track.isPreviewStream && track.id == nil && track.title == "So U Kno" && track.originalPath == page.absoluteString)
        #expect(machine.isLoading)
        #expect(effects.contains(.suspendMain))
    }

    @Test func theSameLinkKeepsThePreviewAndAnotherSwitchesToIt() {
        var machine = PreviewMachine()
        _ = machine.toggle(owner: "row", candidate: .stream(page, title: "A"), main: .nothing)
        #expect(machine.selectionChanged(owner: "row", candidate: .stream(page, title: "A")).isEmpty)
        let other = URL(string: "https://youtu.be/x")!
        let effects = machine.selectionChanged(owner: "row", candidate: .stream(other, title: "B"))
        guard case .scheduleSettle(let token)? = effects.first else { Issue.record("no settle"); return }
        let settled = machine.settle(token: token)
        #expect(settled.contains(.stopAudio))
        #expect(machine.track?.title == "B")
    }

    @Test func aFailedStreamEndsThePreviewAndSaysWhy() {
        var machine = PreviewMachine()
        let started = machine.toggle(owner: "row", candidate: .stream(page, title: "So U Kno"), main: .nothing)
        guard case .resolve(_, let token)? = started.first(where: { if case .resolve = $0 { return true } else { return false } }) else { return }
        let failed = machine.resolved(token: token, .failure(.stream(title: "So U Kno", cause: "yt-dlp isn’t installed")))
        #expect(!machine.isActive)
        #expect(failed.contains(.report(.streamFailed(title: "So U Kno", cause: "yt-dlp isn’t installed"))))
        #expect(PlaybackWords.PreviewRefusal.streamFailed(title: "So U Kno", cause: "yt-dlp isn’t installed").message
                == "Couldn’t preview “So U Kno” — yt-dlp isn’t installed")
    }

    // MARK: The player's words

    @Test func thePlayerSaysResolvingWhileTheLinkIsLookedUpThenHowToStop() {
        let track = Track.previewStream(page: page, title: "So U Kno")
        let resolving = PlayerDisplay.make(current: nil, preview: track, cantPlay: nil, previewIsResolving: true)
        #expect(resolving.secondLine == "Resolving…")
        #expect(!resolving.showsTimes)
        #expect(resolving.title == "So U Kno")
        let playing = PlayerDisplay.make(current: nil, preview: track, cantPlay: nil, previewIsResolving: false)
        #expect(playing.secondLine == "Esc to stop")
        #expect(playing.showsTimes)
        // A library preview keeps its own hint.
        var library = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: "x")
        library.id = 4
        #expect(PlayerDisplay.make(current: nil, preview: library, cantPlay: nil).secondLine == PlaybackWords.previewHint)
    }

    // MARK: Through the view model

    private struct FakeResolver: StreamResolving {
        let answer: Result<URL, StreamResolveError>
        func resolve(_ page: URL) async throws -> URL { try answer.get() }
    }

    private final class FakeFetcher: StreamFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [URL] = []
        var files: [URL] { lock.withLock { made } }
        func fetch(_ stream: URL) async throws -> URL {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("stream-test-\(UUID().uuidString).mp3")
            try Data("audio".utf8).write(to: file)
            lock.withLock { made.append(file) }
            return file
        }
    }

    private func rig(answer: Result<URL, StreamResolveError>) -> (vm: PlaybackViewModel, preview: SilentAudioPlayer, fetcher: FakeFetcher) {
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        let preview = SilentAudioPlayer()
        preview.duration = 240
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { preview },
                                   previewSchedule: { _, _ in })
        let fetcher = FakeFetcher()
        vm.streamPreview = StreamPreviewProvider(resolver: FakeResolver(answer: answer), fetcher: fetcher)
        return (vm, preview, fetcher)
    }

    @Test func aStreamPlaysInThePreviewPlayerAndItsTemporaryFileGoesWhenItEnds() async throws {
        let r = rig(answer: .success(URL(string: "https://cf-media.sndcdn.com/9.mp3")!))
        r.vm.preview.toggle(owner: "row", candidate: .stream(page, title: "So U Kno"))
        #expect(r.vm.preview.isLoading)
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
        let file = try #require(r.fetcher.files.first)
        #expect(r.preview.loaded == [file])
        #expect(r.preview.state == .playing)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(r.vm.preview.track?.isPreviewStream == true)

        #expect(r.vm.preview.escape())
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing of it is kept")
        #expect(r.vm.queueSnapshot.upcoming.isEmpty && r.vm.history.isEmpty)
    }

    @Test func aStreamThatCantBeResolvedSaysWhyInTheStatusBarAndStaysSilent() async throws {
        let r = rig(answer: .failure(.toolMissing))
        r.vm.preview.toggle(owner: "row", candidate: .stream(page, title: "So U Kno"))
        await waitUntil { !r.vm.preview.isActive }
        #expect(r.vm.notice?.text == "Couldn’t preview “So U Kno” — yt-dlp isn’t installed")
        #expect(r.preview.loaded.isEmpty)
        #expect(r.fetcher.files.isEmpty)
    }
}
