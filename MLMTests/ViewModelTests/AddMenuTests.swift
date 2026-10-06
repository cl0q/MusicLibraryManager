import AppKit
import Foundation
import Testing
@testable import MLM

// MARK: - S-QUICKADD (W3-ADD)

@Suite("Add from Link")
@MainActor
struct QuickAddModelTests {
    final class Log {
        var posted: [String] = []
        var downloads: [LinkSuggestion] = []
        var existing: [Int64] = []
        var revealed: [Int64] = []
        var imports: [LinkSuggestion] = []
        var playlistAdds: [(Int64, Int64)] = []
    }

    private func environment(_ log: Log, lookup: LinkLookup = LinkLookup(metadata: LinkMetadata(title: "Rev8617", artist: "Skee Mask", durationSeconds: 348)),
                             outcome: SearchDownloadOutcome = .started(trackID: 7, title: "Rev8617"),
                             ytDlp: Bool = true, running: Bool = false,
                             accounts: ImportTestAccounts? = nil,
                             facts: (title: String, hasFile: Bool, detail: String?)? = nil) -> QuickAddEnvironment {
        QuickAddEnvironment(
            lookUp: { _ in lookup },
            download: { link, _ in log.downloads.append(link); return outcome },
            downloadExisting: { id, _ in log.existing.append(id) },
            addToPlaylist: { log.playlistAdds.append(($0, $1)) },
            isYtDlpAvailable: { ytDlp },
            downloadsRunning: { running },
            accounts: accounts,
            trackFacts: { _ in facts },
            post: { text, _ in log.posted.append(text) },
            reveal: { log.revealed.append($0) },
            importPlaylist: { log.imports.append($0) },
            debounce: .zero,
            sleep: { _ in }
        )
    }

    private let trackURL = "https://soundcloud.com/skeemask/rev8617"

    @Test func aTrackLinkIsLookedUpAndDownloadedAsOneOperation() async {
        let log = Log()
        let model = QuickAddModel(environment: environment(log), text: trackURL)
        await model.settle()
        #expect(model.phase == .track(.track(source: .soundcloud, url: trackURL),
                                      LinkMetadata(title: "Rev8617", artist: "Skee Mask", durationSeconds: 348)))
        #expect(model.primaryTitle == "Download")

        await model.performPrimary()
        #expect(log.downloads.count == 1)
        #expect(log.posted.isEmpty, "the download announces its own start (UC-JOB-08)")
        #expect(model.isFinished, "the sheet closes")
    }

    /// Review S1: SoundCloud links are looked up and stored without share parameters.
    @Test func soundCloudLinksLoseShareParametersBeforeLookupAndStorage() async throws {
        let messy = "https://m.soundcloud.com/skeemask/rev8617/?si=abc123&utm_source=clipboard#t=0:30"
        #expect(LinkSuggestion.classify(messy) == .track(source: .soundcloud, url: trackURL))
        #expect(SoundCloudLink.canonical("https://www.soundcloud.com/a/sets/b?in=x") == "https://soundcloud.com/a/sets/b")
        #expect(SearchDownloadService.linkedTrack(url: LinkSuggestion.classify(messy)!.url, source: .soundcloud, metadata: nil)
                    .originalPath == trackURL)

        let db = try DatabaseManager.inMemory()
        let stored = try await TrackRepository(database: db).insert(
            Track(artist: "Skee Mask", album: "", title: "Rev8617", format: "soundcloud", originalPath: trackURL))
        let found = try await TrackSearchQueries(database: db).trackID(forLink: LinkSuggestion.classify(messy)!.url)
        #expect(found == stored.id, "Already in your library — even with ?si=…")
    }

    @Test func aShortLinkIsFollowedBeforeLookup() async {
        let log = Log()
        var environment = environment(log)
        environment.resolveShortLink = { _ in "https://soundcloud.com/skeemask/rev8617?si=x" }
        let model = QuickAddModel(environment: environment, text: "https://on.soundcloud.com/AbC123")
        await model.settle()
        #expect(model.phase == .track(.track(source: .soundcloud, url: trackURL),
                                      LinkMetadata(title: "Rev8617", artist: "Skee Mask", durationSeconds: 348)))

        var unresolved = self.environment(log)
        unresolved.resolveShortLink = { _ in nil }
        let stays = QuickAddModel(environment: unresolved, text: "https://on.soundcloud.com/AbC123")
        await stays.settle()
        if case .unsupported = stays.phase {} else { Issue.record("an unresolved short link is unsupported: \(stays.phase)") }
    }

    /// Review S8: a remembered `Add to playlist` target that no longer exists is forgotten.
    @Test func aDeletedRememberedPlaylistIsForgotten() async {
        let log = Log()
        QuickAddModel.lastPlaylistID = 99
        defer { QuickAddModel.lastPlaylistID = nil }
        var environment = environment(log)
        environment.existingPlaylistIDs = { [1, 2] }
        let model = QuickAddModel(environment: environment)
        await waitUntil { model.playlistID == nil }
        #expect(QuickAddModel.lastPlaylistID == nil)

        QuickAddModel.lastPlaylistID = 2
        let kept = QuickAddModel(environment: environment)
        #expect(kept.playlistID == 2)
    }

    @Test func aDownloadWhileOthersRunIsQueuedNotRejected() async {
        let log = Log()
        let model = QuickAddModel(environment: environment(log, running: true), text: trackURL)
        await model.settle()
        #expect(model.queuedNote != nil)
        await model.performPrimary()
        #expect(log.downloads.count == 1, "queued, not rejected")
        #expect(log.posted.isEmpty, "a queued download announces itself when it starts")
    }

    @Test func theChosenPlaylistGetsTheNewTrack() async {
        let log = Log()
        let model = QuickAddModel(environment: environment(log), text: trackURL)
        model.playlistID = 42
        await model.settle()
        await model.performPrimary()
        #expect(log.playlistAdds.map(\.0) == [42])
        #expect(log.playlistAdds.map(\.1) == [7])
        model.playlistID = nil
    }

    @Test func aTrackTheLibraryHasIsShownNotAddedTwice() async {
        let log = Log()
        let lookup = LinkLookup(metadata: LinkMetadata(title: "Glue"), libraryTrackID: 5)
        let model = QuickAddModel(environment: environment(log, lookup: lookup, facts: ("Glue (Original Mix)", true, "FLAC")),
                                  text: "https://www.youtube.com/watch?v=Jm0VOzsvtTc")
        await model.settle()
        #expect(model.primaryTitle == "Show in Library")
        await model.performPrimary()
        #expect(log.revealed == [5])
        #expect(log.downloads.isEmpty)
    }

    @Test func aLibraryTrackWithoutAFileOffersDownload() async {
        let log = Log()
        let lookup = LinkLookup(metadata: LinkMetadata(title: "Glue"), libraryTrackID: 5)
        let model = QuickAddModel(environment: environment(log, lookup: lookup, facts: ("Glue", false, nil)), text: trackURL)
        await model.settle()
        #expect(model.primaryTitle == "Download")
        await model.performPrimary()
        #expect(log.existing == [5])
        #expect(log.downloads.isEmpty)
    }

    @Test func aPlaylistLinkHandsOverToTheImport() async {
        let log = Log()
        let url = "https://www.youtube.com/playlist?list=PL4"
        let model = QuickAddModel(environment: environment(log, lookup: LinkLookup(metadata: LinkMetadata(trackCount: 62))), text: url)
        await model.settle()
        #expect(model.primaryTitle == "Import…")
        await model.performPrimary()
        #expect(log.imports == [.playlist(source: .youtube, url: url)])
        #expect(model.isFinished)
    }

    @Test func unsupportedToolMissingSignInAndPrivateAreSaid() async {
        let log = Log()
        let unsupported = QuickAddModel(environment: environment(log), text: "https://bandcamp.com/x")
        await unsupported.settle()
        #expect(unsupported.phase == .unsupported(.unsupported(host: "bandcamp.com", url: "https://bandcamp.com/x")))
        #expect(unsupported.primary == nil)

        let tool = QuickAddModel(environment: environment(log, ytDlp: false), text: "https://youtu.be/abc")
        await tool.settle()
        #expect(tool.phase == .toolMissing)

        let accounts = ImportTestAccounts()
        accounts.states[.soundcloud] = .signInExpired
        let signIn = QuickAddModel(environment: environment(log, lookup: LinkLookup(), accounts: accounts), text: trackURL)
        await signIn.settle()
        #expect(signIn.phase == .signInExpired(.soundcloud))

        let gone = QuickAddModel(environment: environment(log, lookup: LinkLookup()), text: "https://youtu.be/abc")
        await gone.settle()
        #expect(gone.phase == .unavailable(.youtube))
        #expect(log.downloads.isEmpty)
    }

    @Test func aFailureStaysInTheSheet() async {
        let log = Log()
        let model = QuickAddModel(environment: environment(log, outcome: .failed("the disk is full")), text: trackURL)
        await model.settle()
        await model.performPrimary()
        #expect(model.error == "Couldn’t add the track — the disk is full")
        #expect(!model.isFinished)
    }

    @Test func typingWaitsAndNonLinksSaySo() async {
        let log = Log()
        let model = QuickAddModel(environment: environment(log))
        #expect(model.phase == .empty)
        model.urlText = "hello"
        #expect(model.phase == .notALink)
        model.urlText = trackURL
        if case .lookingUp = model.phase {} else { Issue.record("looks the link up: \(model.phase)") }
        await model.settle()
        if case .track = model.phase {} else { Issue.record("expected a track: \(model.phase)") }
    }
}

// MARK: - S-SRC-OAUTH (W3-ADD)

@MainActor
final class SignInCancelFlag {
    var value = false
}

@Suite("Browser sign-in hand-off")
@MainActor
struct SourceSignInModelTests {
    @Test func successContinuesThePlaceThatAskedAndSaysConnected() async {
        let accounts = ImportTestAccounts()
        var posted: [String] = []
        var continued = false
        let model = SourceSignInModel(service: .soundcloud, accounts: accounts,
                                      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                                      post: { posted.append($0) }, gate: SignInGate())
        #expect(model.title == "Sign in to SoundCloud")
        model.start { continued = true }
        #expect(model.phase == .waiting)
        await waitUntil { model.phase == .succeeded }
        #expect(continued)
        #expect(posted == ["SoundCloud connected"])
    }

    @Test func cancelStopsWaitingAndEndsTheBrowserWait() async {
        let accounts = ImportTestAccounts()
        let gate = ImportTestGate()
        let cancelled = SignInCancelFlag()
        accounts.onSignIn = {
            await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { @MainActor in cancelled.value = true; gate.open() } }
            try Task.checkCancellation()
        }
        let model = SourceSignInModel(service: .spotify, accounts: accounts, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                                      gate: SignInGate())
        model.start()
        await waitUntil { gate.isWaiting }
        model.cancel()
        #expect(model.phase == .idle)
        await waitUntil { cancelled.value }
    }

    @Test func noAnswerWithinTheTimeoutSaysItWasNotFinished() async {
        let accounts = ImportTestAccounts()
        let gate = ImportTestGate()
        accounts.onSignIn = {
            await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { @MainActor in gate.open() } }
            try Task.checkCancellation()
        }
        let model = SourceSignInModel(service: .spotify, accounts: accounts, sleep: { _ in }, gate: SignInGate())
        model.start()
        await waitUntil { model.phase == .timedOut }
        #expect(SourceSignInModel.timedOutText == "Sign-in wasn’t finished")
    }

    /// Review H5: one browser sign-in at a time; a released model frees the browser wait.
    @Test func aSecondSignInIsRefusedWhileOneWaitsAndAReleasedModelEndsItsWait() async {
        let gate = SignInGate()
        let accounts = ImportTestAccounts()
        let browser = ImportTestGate()
        let ended = SignInCancelFlag()
        accounts.onSignIn = {
            await withTaskCancellationHandler { await browser.wait() } onCancel: { Task { @MainActor in ended.value = true; browser.open() } }
            try Task.checkCancellation()
        }
        var first: SourceSignInModel? = SourceSignInModel(service: .soundcloud, accounts: accounts,
                                                          sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, gate: gate)
        first?.start()
        await waitUntil { browser.isWaiting }

        let second = SourceSignInModel(service: .spotify, accounts: accounts, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                                       gate: gate)
        second.start()
        #expect(second.phase == .failed(SourceSignInModel.alreadyWaitingText))
        #expect(SourceSignInModel.alreadyWaitingText == "A sign-in is already waiting in your browser")

        first = nil   // the view went away
        await waitUntil { ended.value }
        #expect(!gate.isHeld)
        #expect(first == nil)
    }

    @Test func theLoopbackWaitIsRefusedWhileAnotherWaits() async throws {
        let one = LoopbackOAuthServer(port: 0)
        let waiting = Task { try await one.waitForCallback() }
        await waitUntil { LoopbackOAuthServer.isWaiting }
        await #expect(throws: LoopbackOAuthError.self) {
            _ = try await LoopbackOAuthServer(port: 0).waitForCallback()
        }
        waiting.cancel()
        let result = try? await waiting.value
        #expect(result == nil, "Cancel ends the wait")
        #expect(!LoopbackOAuthServer.isWaiting, "the slot (and the port) are free again")
    }
}

// MARK: - Refresh from Sources (W3-ADD)

@Suite("Refresh from Sources")
@MainActor
struct SourceRefreshServiceTests {
    final class Refresher: SourceLibraryRefreshing {
        var results: [TokenStorage.Service: Result<Int, Error>] = [:]
        func refresh(_ service: TokenStorage.Service) async throws -> SourceRefreshSummary {
            SourceRefreshSummary(newTracks: try (results[service] ?? .success(0)).get())
        }
    }

    @Test func eachSourceIsOneOperationWithACountedResult() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let refresher = Refresher()
        refresher.results = [.soundcloud: .success(6), .spotify: .failure(SpotifyClient.SpotifyError.apiError(statusCode: 401, body: ""))]
        let service = SourceRefreshService(refresher: refresher, activity: center, notificationCenter: NotificationCenter())
        var expired: [TokenStorage.Service] = []
        service.onSignInExpired = { expired.append($0) }

        let outcomes = await service.refreshAll([.soundcloud, .spotify])
        #expect(outcomes[.soundcloud] == .refreshed(SourceRefreshSummary(newTracks: 6)))
        #expect(outcomes[.spotify] == .signInExpired)
        #expect(expired == [.spotify])

        let finished = center.finishedOperations
        let sc = finished.first { $0.title == "Refresh from SoundCloud" }
        let sp = finished.first { $0.title == "Refresh from Spotify" }
        #expect(sc?.kind == .sourceRefresh)
        #expect(sc?.result?.counts.first == ActivityCount(.done, 6, "new tracks"))
        #expect(sp?.state == .failed)
        #expect(sp?.result?.failureCause == "Sign-in expired (Spotify)")
        #expect(sp?.result?.failureGroups.first?.fix == .reconnect(source: "Spotify"))
    }

    @Test func aTransportFailureIsSaidInPlainWords() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let refresher = Refresher()
        refresher.results = [.soundcloud: .failure(URLError(.notConnectedToInternet))]
        let service = SourceRefreshService(refresher: refresher, activity: center, notificationCenter: NotificationCenter())
        #expect(await service.refresh(.soundcloud) == .failed("SoundCloud didn’t answer"))
    }
}

// MARK: - The Add menu and its presenter (W3-ADD)

@Suite("Add menu")
@MainActor
struct AddMenuWiringTests {
    @Test func addFromLinkAndRefreshFromSourcesAreWired() {
        #expect(MenuCommand.addFromLink.entry.wiring == .app)
        #expect(MenuCommand.refreshFromSources.entry.wiring == .app)
        #expect(MenuCommand.addFromLink.shortcut?.description == "⌘U")
        // W3-PL wires these two.
        // W3-PL wired New Playlist Folder and Import M3U…; every Add-menu item is live now.
        #expect(!MenuCommand.newPlaylistFolder.isPending)
        #expect(!MenuCommand.importM3U.isPending)
        #expect(AddMenu.Unavailable.refreshFromSources == "No source is connected")
    }

    @Test func thePasteboardPrefillsOnlyALink() {
        #expect(ImportSheetsPresenter.pasteboardLink(" https://youtu.be/x \n") == "https://youtu.be/x")
        #expect(ImportSheetsPresenter.pasteboardLink("two words") == nil)
        #expect(ImportSheetsPresenter.pasteboardLink(nil) == nil)
    }

    /// A track link opens Add from Link with what the search field already knew (no second
    /// lookup, no network here). Playlist links go to S-IMPORT (`presentImport`, covered by
    /// `ImportPlaylistModelTests` through `start(with:)`).
    @Test func trackLinksOpenAddFromLinkWithTheFieldsLookup() {
        let presenter = ImportSheetsPresenter(container: DependencyContainer.shared, statusBar: StatusBarCenter(),
                                              navigation: NavigationModel())
        presenter.presentQuickAdd(for: .track(source: .youtube, url: "https://youtu.be/x"),
                                  lookup: LinkLookup(metadata: LinkMetadata(title: "Good Lies")))
        guard case .quickAdd(let quick) = presenter.sheet else { Issue.record("expected quick add"); return }
        #expect(quick.urlText == "https://youtu.be/x")
    }

    @Test func theWindowInstallsThePresenterAndTheInterimPathIsGone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("MLM/Views/Import/ImportSheetsHost.swift"), encoding: .utf8)
        #expect(host.contains("QuickAddRouter.shared.presenter = presenter"))
        let content = try String(contentsOf: root.appendingPathComponent("MLM/Views/ContentView/ContentView.swift"), encoding: .utf8)
        #expect(!content.contains("QuickAddRouter.Interim"))
        #expect(!content.contains("showRemotePlaylistsWindow"))
        #expect(content.contains("allowedContentTypes: [.folder, .audio]"))
        let delegate = try String(contentsOf: root.appendingPathComponent("MLM/App/AppDelegate.swift"), encoding: .utf8)
        #expect(!delegate.contains("RemotePlaylistsView"))
    }
}
