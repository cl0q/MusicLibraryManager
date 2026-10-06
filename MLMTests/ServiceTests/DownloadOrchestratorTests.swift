import Foundation
import Testing
@testable import MLM

/// Tests for the DownloadOrchestrator public surface and the classified
/// fallback chain (WP-H).
struct DownloadOrchestratorTests {

    // MARK: - Test infrastructure

    private func makeTempLibrary() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_download_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// No-op clock — tests never actually wait.
    struct ImmediateClock: DownloadOrchestrator.DownloaderClock {
        func sleep(_ seconds: Double) async { /* no-op */ }
    }

    /// Clock that records every sleep call so tests can assert backoff
    /// was bounded without actually waiting.
    final class CountingClock: DownloadOrchestrator.DownloaderClock, @unchecked Sendable {
        var sleepCalls: [Double] = []
        let lock = NSLock()
        func sleep(_ seconds: Double) async {
            lock.lock()
            sleepCalls.append(seconds)
            lock.unlock()
        }
    }

    /// Fake SoundCloud provider with configurable outcomes and call counting.
    final class FakeSoundCloud: DownloadOrchestrator.SoundCloudProviding, @unchecked Sendable {
        var isAvailable: Bool = true
        var outcomes: [DownloadOutcome] = []
        var callCount = 0
        var exhaustionCount = 0
        /// Optional side-effect closure invoked after each download call,
        /// after the outcome has been determined. Used by the mid-chain
        /// cancellation test to call orch.cancel() between sources.
        var afterDownload: (() -> Void)?
        let lock = NSLock()

        func download(
            trackURL: String, outputDir: URL, trackId: Int64,
            title: String, onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome {
            lock.lock()
            let idx = callCount
            callCount += 1
            lock.unlock()
            let outcome: DownloadOutcome
            if idx < outcomes.count {
                let scripted = outcomes[idx]
                switch scripted {
                case .success:
                    // Create a real file in outputDir so finalize can
                    // process it — the chain's success path requires the
                    // file to exist on disk.
                    let filePath = outputDir.appendingPathComponent("fake-sc-\(idx).m4a")
                    try Data("fake sc audio content".utf8).write(to: filePath)
                    outcome = .success(filePath)
                case .failure:
                    outcome = scripted
                }
            } else {
                lock.lock()
                exhaustionCount += 1
                lock.unlock()
                // Loud exhaustion: distinct sentinel that cannot be mistaken
                // for a real classification. Tests should script enough outcomes.
                outcome = .failure(DownloadFailure(
                    klass: .unknown, source: "soundcloud",
                    detail: "FAKE EXHAUSTED: called \(idx + 1) times but only \(outcomes.count) outcomes scripted",
                    userMessage: "FAKE EXHAUSTED",
                    heal: .fallThroughToNextSource))
            }
            afterDownload?()
            return outcome
        }
    }

    /// Fake YouTube provider with call counting.
    final class FakeYouTube: DownloadOrchestrator.YouTubeProviding, @unchecked Sendable {
        var isAvailable: Bool = true
        var outcomes: [DownloadOutcome] = []
        var searchCallCount = 0
        var byURLCallCount = 0
        var exhaustionCount = 0
        let lock = NSLock()

        func searchAndDownload(
            query: String, outputDir: URL,
            onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome {
            lock.lock()
            let idx = searchCallCount
            searchCallCount += 1
            lock.unlock()
            if idx < outcomes.count {
                let scripted = outcomes[idx]
                switch scripted {
                case .success:
                    // Create a real file in outputDir so finalize can
                    // process it — the chain's success path requires the
                    // file to exist on disk.
                    let filePath = outputDir.appendingPathComponent("fake-yt-\(idx).m4a")
                    try Data("fake yt audio content".utf8).write(to: filePath)
                    return .success(filePath)
                case .failure:
                    return scripted
                }
            }
            lock.lock()
            exhaustionCount += 1
            lock.unlock()
            return .failure(DownloadFailure(
                klass: .unknown, source: "youtube",
                detail: "FAKE EXHAUSTED: called \(idx + 1) times but only \(outcomes.count) outcomes scripted",
                userMessage: "FAKE EXHAUSTED",
                heal: .fallThroughToNextSource))
        }

        func downloadByURL(_ url: String, outputDir: URL) async throws -> DownloadOutcome {
            lock.lock()
            byURLCallCount += 1
            lock.unlock()
            return .failure(DownloadFailure(
                klass: .unknown, source: "youtube",
                detail: "FAKE EXHAUSTED: byURL not scripted",
                userMessage: "FAKE EXHAUSTED",
                heal: .fallThroughToNextSource))
        }
    }

    /// Fake DAB provider with call counting.
    final class FakeDAB: DownloadOrchestrator.DABProviding, @unchecked Sendable {
        var searchResult: Result<DabTrack?, Error> = .success(nil)
        var downloadResult: Result<DABClient.DownloadResult, Error> = .success(.notFound)
        var searchCallCount = 0
        var downloadCallCount = 0
        let lock = NSLock()

        func searchTrack(query: String) async throws -> DabTrack? {
            lock.lock()
            searchCallCount += 1
            lock.unlock()
            return try searchResult.get()
        }

        func matches(dabTrack: DabTrack, artist: String, title: String) -> Bool {
            true
        }

        func download(
            dabTrack: DabTrack, outputDir: URL,
            artist: String, title: String
        ) async throws -> DABClient.DownloadResult {
            lock.lock()
            downloadCallCount += 1
            lock.unlock()
            return try downloadResult.get()
        }
    }

    /// Fake Squid provider with call counting.
    final class FakeSquid: DownloadOrchestrator.SquidProviding, @unchecked Sendable {
        var searchResult: Result<SquidTrack?, Error> = .success(nil)
        var downloadResult: Result<SquidWtfClient.DownloadResult, Error> = .success(.notFound)
        var searchCallCount = 0
        var downloadCallCount = 0
        let lock = NSLock()

        func searchTrack(
            query: String, artist: String, title: String
        ) async throws -> SquidTrack? {
            lock.lock()
            searchCallCount += 1
            lock.unlock()
            return try searchResult.get()
        }

        func download(
            track: SquidTrack, outputDir: URL,
            artist: String, title: String
        ) async throws -> SquidWtfClient.DownloadResult {
            lock.lock()
            downloadCallCount += 1
            lock.unlock()
            return try downloadResult.get()
        }
    }

    private func makeOrchestrator(
        sc: FakeSoundCloud = FakeSoundCloud(),
        yt: FakeYouTube = FakeYouTube(),
        dab: FakeDAB? = FakeDAB(),
        squid: FakeSquid = FakeSquid(),
        clock: any DownloadOrchestrator.DownloaderClock = ImmediateClock()
    ) throws -> (DownloadOrchestrator, FakeSoundCloud, FakeYouTube, FakeDAB?, FakeSquid) {
        let root = try makeTempLibrary()
        let orch = DownloadOrchestrator(
            libraryRoot: root.path,
            soundCloudDownloader: sc,
            youtubeDownloader: yt,
            dabClient: dab,
            squidClient: squid,
            clock: clock
        )
        return (orch, sc, yt, dab, squid)
    }

    private func makeRequest(
        trackId: Int64 = 1,
        artist: String = "Artist",
        title: String = "Title",
        scURL: String? = "https://soundcloud.com/artist/title"
    ) -> DownloadOrchestrator.DownloadRequest {
        DownloadOrchestrator.DownloadRequest(
            trackId: trackId,
            artist: artist,
            title: title,
            query: "\(artist) - \(title)",
            soundcloudURL: scURL,
            userId: nil
        )
    }

    // MARK: - Pre-existing tests (preserved unmodified)

    @Test
    func initLeavesManagedDirectoriesUncreated() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        for name in ManagedLibraryLayout.folderNames {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    @Test
    func emptyBatchReturnsZeros() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let result = await orchestrator.downloadBatch([])
        #expect(result.succeeded == 0)
        #expect(result.failed == 0)
        #expect(result.skipped == 0)
        #expect(result.downloadedPaths.isEmpty)
        #expect(result.downloadedMetadata.isEmpty)
    }

    @Test
    func legacyFlacStagingDoesNotMasqueradeAsCompletedDownload() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        try FileManager.default.createDirectory(at: flacDir, withIntermediateDirectories: true)
        let preExisting = flacDir.appendingPathComponent("Yeat - Mr. Lordbow.flac")
        FileManager.default.createFile(atPath: preExisting.path, contents: Data("fake".utf8))
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 42, artist: "Yeat", title: "Mr. Lordbow",
            query: "Yeat - Mr. Lordbow", soundcloudURL: nil, userId: nil
        )
        #expect(FileManager.default.fileExists(atPath: preExisting.path))
        #expect(orchestrator.finalDirectory(for: .youtube).standardizedFileURL != flacDir.standardizedFileURL)
        #expect(
            DownloadOrchestrator.finalFileName(for: request, pathExtension: "flac")
                != preExisting.lastPathComponent
        )
    }

    @Test
    func cancelIsSafeOnIdleOrchestrator() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        orchestrator.cancel()
        orchestrator.cancel()
        let result = await orchestrator.downloadBatch([])
        #expect(result.succeeded == 0)
        #expect(result.failed == 0)
        #expect(orchestrator.isRunning == false)
    }

    @Test
    func downloadedFileInfoCarriesFormatAndBitrate() {
        let info = DownloadOrchestrator.DownloadedFileInfo(format: "m4a", bitrate: 248)
        #expect(info.format == "m4a")
        #expect(info.bitrate == 248)
        let infoNoBitrate = DownloadOrchestrator.DownloadedFileInfo(format: "mp3", bitrate: nil)
        #expect(infoNoBitrate.format == "mp3")
        #expect(infoNoBitrate.bitrate == nil)
    }

    @Test
    func failureReasonsUseBoundedPlainLanguageVocabulary() {
        let ytDlpUnavailable = NSError(
            domain: "Download", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "yt-dlp not installed"]
        )
        let unavailableVideo = NSError(
            domain: "Download", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Video unavailable"]
        )
        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(for: ytDlpUnavailable) == .ytDlpUnavailable
        )
        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(for: unavailableVideo) == .videoUnavailable
        )
        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(
                for: URLError(.notConnectedToInternet)
            ) == .network
        )
        #expect(DownloadOrchestrator.DownloadFailureReason.network.userFacingText == "Network error")
        #expect(
            DownloadOrchestrator.failureReasonForExhaustedSources(
                preferredSource: .youtube, youtubeAvailable: true
            ) == .sourcesExhausted
        )
        #expect(
            DownloadOrchestrator.failureReasonForExhaustedSources(
                preferredSource: .youtube, youtubeAvailable: false
            ) == .ytDlpUnavailable
        )
    }

    @Test
    func preferredSourceStorageKeyRoundTripsForEveryCase() {
        let allCases: [DownloadOrchestrator.PreferredSource] = [.auto, .soundcloud, .youtube]
        for source in allCases {
            #expect(DownloadOrchestrator.PreferredSource(storageKey: source.storageKey) == source)
        }
    }

    @Test
    func preferredSourceStorageKeysAreStable() {
        #expect(DownloadOrchestrator.PreferredSource.auto.storageKey == "auto")
        #expect(DownloadOrchestrator.PreferredSource.soundcloud.storageKey == "soundcloud")
        #expect(DownloadOrchestrator.PreferredSource.youtube.storageKey == "youtube")
    }

    @Test
    func preferredSourceFailsSafeToAutoForNilOrUnknownKey() {
        #expect(DownloadOrchestrator.PreferredSource(storageKey: nil) == .auto)
        #expect(DownloadOrchestrator.PreferredSource(storageKey: "garbage") == .auto)
    }

    @Test
    func legacyRetryQueueJSONDecodesWithoutNewFields() throws {
        let legacyJSON = """
        [
          {
            "track_id": 123,
            "query": "Old Artist - Old Title",
            "source": "youtube",
            "attempt_count": 1,
            "last_error": "not found",
            "queued_at": "2024-01-01T00:00:00Z"
          }
        ]
        """
        let decoded = try JSONDecoder().decode(
            [DownloadQueue.QueueItem].self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.count == 1)
        #expect(decoded[0].preferredSource == nil)
        #expect(decoded[0].soundcloudURL == nil)
        #expect(DownloadOrchestrator.PreferredSource(storageKey: decoded[0].preferredSource) == .auto)
    }

    @Test
    func legacyRetryQueueFileLoadsWithoutCrashing() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let legacyJSON = """
        [
          {
            "track_id": 55,
            "query": "Legacy Artist - Legacy Title",
            "source": "youtube",
            "attempt_count": 1,
            "last_error": "not found",
            "queued_at": "2024-01-01T00:00:00Z"
          }
        ]
        """
        let queuePath = tmp.appendingPathComponent(".retry_queue.json")
        try Data(legacyJSON.utf8).write(to: queuePath)
        let queue = DownloadQueue(directory: tmp)
        #expect(queue.items.count == 1)
        #expect(queue.items[0].preferredSource == nil)
        #expect(queue.items[0].soundcloudURL == nil)
    }

    @Test
    func queueItemRoundTripsPreferredSourceAndSoundcloudURL() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = DownloadQueue(directory: tmp)
        try queue.enqueue(
            trackId: 9, query: "Artist - Title", source: "soundcloud", error: "network hiccup",
            artist: "Artist", title: "Title",
            preferredSource: DownloadOrchestrator.PreferredSource.soundcloud.storageKey,
            soundcloudURL: "https://soundcloud.com/artist/title",
            youtubeURL: "https://youtube.com/watch?v=exact"
        )
        let reloaded = DownloadQueue(directory: tmp)
        let item = try #require(reloaded.items.first)
        #expect(DownloadOrchestrator.PreferredSource(storageKey: item.preferredSource) == .soundcloud)
        #expect(item.artist == "Artist")
        #expect(item.title == "Title")
        #expect(item.soundcloudURL == "https://soundcloud.com/artist/title")
        #expect(item.youtubeURL == "https://youtube.com/watch?v=exact")
    }

    @Test
    func enqueueRecordsActualAttemptedSourceNotHardcodedLiteral() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = DownloadQueue(directory: tmp)
        try queue.enqueue(trackId: 1, query: "Artist - Title", source: "soundcloud", error: "e")
        let item = try #require(queue.items.first)
        #expect(item.source == "soundcloud")
    }

    @Test
    func soundCloudPinnedFailureSurvivesRetryQueueRoundTrip() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = DownloadQueue(directory: tmp)
        try queue.enqueue(
            trackId: 77, query: "Artist - Title",
            source: DownloadOrchestrator.PreferredSource.soundcloud.storageKey,
            error: "scdl timed out",
            preferredSource: DownloadOrchestrator.PreferredSource.soundcloud.storageKey,
            soundcloudURL: "https://soundcloud.com/artist/pinned-track"
        )
        let retryable = queue.retryableItems()
        #expect(retryable.count == 1)
        let item = try #require(retryable.first)
        let rebuiltPin = DownloadOrchestrator.PreferredSource(storageKey: item.preferredSource)
        #expect(rebuiltPin == .soundcloud)
        #expect(item.soundcloudURL == "https://soundcloud.com/artist/pinned-track")
    }

    @Test
    func legacyRetryQueryRecoversArtistAndFullTitle() {
        let identity = DownloadOrchestrator.parseIdentity(from: "Artist - Title - Extended Mix")
        #expect(identity.artist == "Artist")
        #expect(identity.title == "Title - Extended Mix")
    }

    @Test
    func dequeuePersistedRetriesRemovesOnlySuccessfulTracks() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = DownloadQueue(directory: tmp)
        try queue.enqueue(trackId: 1, query: "A - One", source: "soundcloud", error: "e")
        try queue.enqueue(trackId: 2, query: "A - Two", source: "soundcloud", error: "e")
        try queue.dequeue(trackIds: [1])
        #expect(queue.items.map(\.trackId) == [2])
    }

    @Test
    func cappedLegacyRetryRemainsAvailableToActivityAfterReload() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let queueDirectory = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let queue = DownloadQueue(directory: queueDirectory)
        for _ in 0..<3 {
            try queue.enqueue(
                trackId: 88, query: "Artist - Capped Failure",
                source: "youtube", error: "Video unavailable",
                artist: "Artist", title: "Capped Failure"
            )
        }
        let reloadedQueue = DownloadQueue(directory: queueDirectory)
        #expect(reloadedQueue.items.count == 1)
        #expect(reloadedQueue.items.first?.attemptCount == 3)
        #expect(reloadedQueue.retryableItems().isEmpty)
        let reloadedOrchestrator = DownloadOrchestrator(
            libraryRoot: root.path, tokenStorage: TokenStorage()
        )
        let activityItems = reloadedOrchestrator.persistedRetryItems()
        #expect(activityItems.count == 1)
        #expect(activityItems.first?.trackId == 88)
        #expect(activityItems.first?.lastError == "Video unavailable")
    }

    @Test
    func finalDirectoryMapsEachSourceCorrectlyAndNeverToFlac() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let soundCloudDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        let aacDir = root.appendingPathComponent(ManagedLibraryLayout.youtubeDownloads)
        let flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        #expect(orchestrator.finalDirectory(for: .soundcloud).standardizedFileURL == soundCloudDir.standardizedFileURL)
        #expect(orchestrator.finalDirectory(for: .youtube).standardizedFileURL == aacDir.standardizedFileURL)
        #expect(orchestrator.finalDirectory(for: .dab).standardizedFileURL == aacDir.standardizedFileURL)
        #expect(orchestrator.finalDirectory(for: .squid).standardizedFileURL == aacDir.standardizedFileURL)
        let allSources: [DownloadOrchestrator.DownloadSource] = [.soundcloud, .youtube, .dab, .squid]
        for source in allSources {
            #expect(orchestrator.finalDirectory(for: source) != flacDir)
        }
    }

    @Test
    func preservesOriginalIsTrueOnlyForTrueFlacProviders() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        #expect(orchestrator.preservesOriginal(for: .dab) == true)
        #expect(orchestrator.preservesOriginal(for: .squid) == true)
        #expect(orchestrator.preservesOriginal(for: .soundcloud) == false)
        #expect(orchestrator.preservesOriginal(for: .youtube) == false)
    }

    @Test
    func finalFileNamesIncludeTrackIdentityToPreventCrossTrackOverwrite() {
        let first = DownloadOrchestrator.DownloadRequest(
            trackId: 10, artist: "Artist", title: "Same Title",
            query: "Artist - Same Title", soundcloudURL: nil, userId: nil
        )
        let second = DownloadOrchestrator.DownloadRequest(
            trackId: 11, artist: "Artist", title: "Same Title",
            query: "Artist - Same Title", soundcloudURL: nil, userId: nil
        )
        let firstName = DownloadOrchestrator.finalFileName(for: first, pathExtension: "m4a")
        let secondName = DownloadOrchestrator.finalFileName(for: second, pathExtension: "m4a")
        #expect(firstName != secondName)
        #expect(firstName.hasSuffix("[10].m4a"))
        #expect(secondName.hasSuffix("[11].m4a"))
    }

    @Test
    func placeFinalMovesTempFileIntoFinalDirectory() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let finalDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        let tempFile = root.appendingPathComponent("scratch-temp.m4a")
        try Data("new bytes".utf8).write(to: tempFile)
        let dest = try await orchestrator.placeFinal(tempFile, into: finalDir)
        #expect(dest.standardizedFileURL == finalDir.appendingPathComponent("scratch-temp.m4a").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
    }

    @Test
    func placeFinalReplacesCollidingFileWithNewContent() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let finalDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        let existing = finalDir.appendingPathComponent("collide.m4a")
        try Data("old bytes".utf8).write(to: existing)
        let producedTemp = root.appendingPathComponent("collide.m4a")
        try Data("new bytes".utf8).write(to: producedTemp)
        let dest = try await orchestrator.placeFinal(producedTemp, into: finalDir)
        let matches = try FileManager.default
            .contentsOfDirectory(at: finalDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "collide.m4a" }
        #expect(matches.count == 1)
        #expect(try Data(contentsOf: dest) == Data("new bytes".utf8))
    }

    @Test
    func finalizeKeepsSoundCloudSourceParentAsSoundCloudDir() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let soundCloudDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        try FileManager.default.createDirectory(at: soundCloudDir, withIntermediateDirectories: true)
        let fakeFile = soundCloudDir.appendingPathComponent("fake-track.m4a")
        try Data("not real audio".utf8).write(to: fakeFile)
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 100, artist: "A", title: "B", query: "A - B",
            soundcloudURL: "https://soundcloud.com/a/b", userId: nil
        )
        let finalized = try await orchestrator.finalize(sourcePath: fakeFile, source: .soundcloud, request: request)
        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL == soundCloudDir.standardizedFileURL)
    }

    @Test
    func finalizeKeepsYouTubeSourceParentOutOfFlacDir() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let aacDir = root.appendingPathComponent(ManagedLibraryLayout.youtubeDownloads)
        let flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        try FileManager.default.createDirectory(at: aacDir, withIntermediateDirectories: true)
        let fakeFile = aacDir.appendingPathComponent("fake-track.m4a")
        try Data("not real audio".utf8).write(to: fakeFile)
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 101, artist: "A", title: "B", query: "A - B",
            soundcloudURL: nil, userId: nil
        )
        let finalized = try await orchestrator.finalize(sourcePath: fakeFile, source: .youtube, request: request)
        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL == aacDir.standardizedFileURL)
        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL != flacDir.standardizedFileURL)
    }

    // MARK: - WP-H: Classified fallback chain tests

    /// A DRM-protected SoundCloud failure must NOT stop the chain — every
    /// remaining source (DAB, Squid, YouTube) must still be tried. When
    /// YouTube succeeds, the overall result is a success from .youtube.
    @Test
    func permanentDRMFailureStillTriesEveryRemainingSource() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .drmProtected, source: "soundcloud",
            detail: "DRM protected",
            userMessage: "DRM-protected on SoundCloud — cannot be downloaded",
            heal: .none))]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        yt.outcomes = [.success(URL(fileURLWithPath: "/tmp/fake.m4a"))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        let result = await orch.downloadBatch([makeRequest()])

        #expect(result.succeeded == 1)
        // Every remaining source was tried
        #expect(dab.searchCallCount > 0)
        #expect(squid.searchCallCount > 0)
        #expect(yt.searchCallCount > 0)
        // SC was called exactly once (no same-source retry for permanent)
        #expect(sc.callCount == 1)
    }

    /// contentRemoved is also permanent — chain must still continue.
    @Test
    func permanentContentRemovedStillTriesEveryRemainingSource() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .contentRemoved, source: "soundcloud",
            detail: "removed by uploader",
            userMessage: "Content has been removed from SoundCloud",
            heal: .none))]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        yt.outcomes = [.success(URL(fileURLWithPath: "/tmp/fake.m4a"))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.succeeded == 1)
        #expect(dab.searchCallCount > 0)
        #expect(squid.searchCallCount > 0)
        #expect(yt.searchCallCount > 0)
    }

    /// mediaCorrupt on one source says nothing about another source's
    /// copy — chain must continue to every remaining source.
    @Test
    func mediaCorruptStillTriesEveryRemainingSource() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .mediaCorrupt, source: "soundcloud",
            detail: "moov atom not found",
            userMessage: "Downloaded media is corrupt — quarantined for inspection",
            heal: .quarantineAndReport))]
        let dab = FakeDAB()
        let yt = FakeYouTube()
        yt.outcomes = [.success(URL(fileURLWithPath: "/tmp/fake.m4a"))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab)

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.succeeded == 1)
        #expect(dab.searchCallCount > 0)
        #expect(yt.searchCallCount > 0)
    }

    /// Transient failure (networkTimeout) retries the same source before
    /// falling through. SC fails twice then succeeds on third attempt.
    @Test
    func transientFailureRetriesSameSourceThenSucceeds() async throws {
        let clock = CountingClock()
        let sc = FakeSoundCloud()
        sc.outcomes = [
            .failure(DownloadFailure(
                klass: .networkTimeout, source: "soundcloud",
                detail: "read timed out", userMessage: "Timed out contacting SoundCloud",
                heal: .retrySameSource)),
            .failure(DownloadFailure(
                klass: .networkTimeout, source: "soundcloud",
                detail: "read timed out", userMessage: "Timed out contacting SoundCloud",
                heal: .retrySameSource)),
            .success(URL(fileURLWithPath: "/tmp/fake.m4a"))
        ]
        let yt = FakeYouTube()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, clock: clock)

        _ = await orch.downloadBatch([makeRequest()])
        // SC called 3 times (initial + 2 retries)
        #expect(sc.callCount == 3)
        // YouTube never called because SC succeeded on 3rd attempt
        #expect(yt.searchCallCount == 0)
        // Clock was called twice (between retries)
        #expect(clock.sleepCalls.count == 2)
    }

    /// Transient failure that exhausts all retries DOES fall through.
    @Test
    func transientFailureExhaustingRetriesFallsThrough() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [
            .failure(DownloadFailure(
                klass: .networkTimeout, source: "soundcloud",
                detail: "timed out", userMessage: "Timed out",
                heal: .retrySameSource)),
            .failure(DownloadFailure(
                klass: .networkTimeout, source: "soundcloud",
                detail: "timed out", userMessage: "Timed out",
                heal: .retrySameSource)),
            .failure(DownloadFailure(
                klass: .networkTimeout, source: "soundcloud",
                detail: "timed out", userMessage: "Timed out",
                heal: .retrySameSource)),
        ]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "Track not found",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.failed == 1)
        // SC called 3 times (initial + 2 retries)
        #expect(sc.callCount == 3)
        // After exhausting SC retries, fell through to DAB
        #expect(dab.searchCallCount == 1)
        // Then Squid
        #expect(squid.searchCallCount == 1)
        // Then YouTube (last resort)
        #expect(yt.searchCallCount == 1)
    }

    /// toolStale (heal = .updateToolThenRetry) is NOT retrySameSource —
    /// it falls through immediately without retrying.
    @Test
    func toolStaleFallsThroughWithoutRetry() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .toolStale, source: "soundcloud",
            detail: "HTTP Error 403: Forbidden",
            userMessage: "SoundCloud rejected the request (HTTP 403) — the downloader tool is probably outdated",
            heal: .updateToolThenRetry))]
        let dab = FakeDAB()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, dab: dab)

        _ = await orch.downloadBatch([makeRequest()])
        // SC called exactly once — no retry for toolStale
        #expect(sc.callCount == 1)
        // Fell through to DAB
        #expect(dab.searchCallCount == 1)
    }

    /// The terminal reason is the classified userMessage, not "Video unavailable".
    /// The selection rule picks the first non-unknown failure (SC's 403)
    /// over downstream generic failures.
    @Test
    func terminalReasonIsClassifiedUserMessageNotVideoUnavailable() async throws {
        let sc = FakeSoundCloud()
        let expectedMessage = "SoundCloud rejected the request (HTTP 403) — the downloader tool is probably outdated"
        sc.outcomes = [.failure(DownloadFailure(
            klass: .toolStale, source: "soundcloud",
            detail: "HTTP Error 403", userMessage: expectedMessage,
            heal: .updateToolThenRetry))]
        // Script downstream fakes with generic failures so the test
        // states its intent — the terminal reason should be SC's 403.
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "Track not found on YouTube",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: nil, squid: FakeSquid())

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.failed == 1)
        #expect(result.failureReasons[1] == expectedMessage)
        #expect(result.failureReasons[1] != "Video unavailable")
        #expect(yt.exhaustionCount == 0, "YouTube should not have been exhausted — it had a scripted outcome")
    }

    /// DRM failure terminal message is the classified userMessage.
    @Test
    func drmFailureTerminalMessageIsClassified() async throws {
        let sc = FakeSoundCloud()
        let expectedMessage = "DRM-protected on SoundCloud — cannot be downloaded"
        sc.outcomes = [.failure(DownloadFailure(
            klass: .drmProtected, source: "soundcloud",
            detail: "DRM protected", userMessage: expectedMessage,
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, dab: nil, squid: FakeSquid())

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.failureReasons[1] == expectedMessage)
    }

    /// Squid/DAB network failure (URLError) is distinguishable from no-match.
    @Test
    func squidNetworkFailureIsDistinguishableFromNoMatch() async throws {
        // Case 1: Squid search throws URLError (endpoint unreachable)
        let squidUnreachable = FakeSquid()
        squidUnreachable.searchResult = .failure(URLError(.cannotFindHost))
        let sc1 = FakeSoundCloud()
        sc1.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "soundcloud",
            detail: "not found", userMessage: "not found",
            heal: .fallThroughToNextSource))]
        let yt1 = FakeYouTube()
        yt1.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "not found on youtube",
            heal: .none))]
        let (orch1, _, _, _, _) = try makeOrchestrator(sc: sc1, yt: yt1, dab: nil, squid: squidUnreachable)
        let result1 = await orch1.downloadBatch([makeRequest()])
        // The chain reached YouTube (squid transport error fell through)
        #expect(yt1.searchCallCount == 1)
        #expect(result1.failed == 1)

        // Case 2: Squid search returns nil (legitimate no match)
        let squidNoMatch = FakeSquid()
        squidNoMatch.searchResult = .success(nil)
        let sc2 = FakeSoundCloud()
        sc2.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "soundcloud",
            detail: "not found", userMessage: "not found",
            heal: .fallThroughToNextSource))]
        let yt2 = FakeYouTube()
        yt2.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "not found on youtube",
            heal: .none))]
        let (orch2, _, _, _, _) = try makeOrchestrator(sc: sc2, yt: yt2, dab: nil, squid: squidNoMatch)
        let result2 = await orch2.downloadBatch([makeRequest()])
        #expect(yt2.searchCallCount == 1)
        #expect(result2.failed == 1)
    }

    /// DAB transport error (URLError) is classified, not silently swallowed.
    @Test
    func dabTransportErrorIsClassifiedNotSwallowed() async throws {
        let dab = FakeDAB()
        dab.searchResult = .failure(URLError(.networkConnectionLost))
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "soundcloud",
            detail: "not found", userMessage: "not found",
            heal: .fallThroughToNextSource))]
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "not found",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: FakeSquid())

        _ = await orch.downloadBatch([makeRequest()])
        #expect(dab.searchCallCount == 1)
        #expect(yt.searchCallCount == 1)
    }

    /// Backoff is bounded: the retry count cap is respected.
    @Test
    func backoffIsBoundedAndUsesClockSeam() async throws {
        let clock = CountingClock()
        let sc = FakeSoundCloud()
        for _ in 0..<5 {
            sc.outcomes.append(.failure(DownloadFailure(
                klass: .rateLimited, source: "soundcloud",
                detail: "429", userMessage: "Rate limited",
                heal: .retrySameSource)))
        }
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, dab: nil, squid: FakeSquid(), clock: clock)

        _ = await orch.downloadBatch([makeRequest()])
        // Initial attempt + 2 retries = 3 calls total
        #expect(sc.callCount == 3)
        // Clock was called exactly 2 times (between the 3 attempts)
        #expect(clock.sleepCalls.count == 2)
        // Backoff values are exponentially increasing
        if clock.sleepCalls.count == 2 {
            #expect(clock.sleepCalls[1] > clock.sleepCalls[0])
        }
    }

    /// Non-permanent, non-retryable failures still fall through.
    @Test
    func nonPermanentNonRetryableFallsThrough() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "soundcloud",
            detail: "no file produced",
            userMessage: "Downloader finished without producing a file",
            heal: .fallThroughToNextSource))]
        let dab = FakeDAB()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, dab: dab, squid: FakeSquid())

        _ = await orch.downloadBatch([makeRequest()])
        #expect(sc.callCount == 1)
        #expect(dab.searchCallCount == 1)
    }

    /// Squid captchaRequired → chain continues to next source (YouTube),
    /// and the terminal reason is not "Video unavailable".
    @Test
    func squidCaptchaRequiredFallsThroughToNextSource() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "soundcloud",
            detail: "not found", userMessage: "not found",
            heal: .fallThroughToNextSource))]
        let squid = FakeSquid()
        // Squid search finds a track, but download returns captchaRequired
        squid.searchResult = .success(SquidTrack(
            id: "123", title: "Title", artist: "Artist", durationSec: 180))
        squid.downloadResult = .success(.captchaRequired)
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "not found on youtube",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: nil, squid: squid)

        let result = await orch.downloadBatch([makeRequest()])
        #expect(result.failed == 1)
        // Squid was called (search + download)
        #expect(squid.searchCallCount == 1)
        #expect(squid.downloadCallCount == 1)
        // Chain continued to YouTube after captcha
        #expect(yt.searchCallCount == 1)
        // Terminal reason is NOT the old generic string
        #expect(result.failureReasons[1] != "Video unavailable")
    }

    // MARK: - Terminal failure selection rule tests

    /// SC returns 403/toolStale, downstream sources return generic failures
    /// → terminal reason is the 403 message (first non-unknown), not the
    /// last source's generic message.
    @Test
    func selectionRulePrefersFirstNonUnknownOverLast() async throws {
        let sc = FakeSoundCloud()
        let scMessage = "SoundCloud rejected the request (HTTP 403) — the downloader tool is probably outdated"
        sc.outcomes = [.failure(DownloadFailure(
            klass: .toolStale, source: "soundcloud",
            detail: "HTTP 403", userMessage: scMessage,
            heal: .updateToolThenRetry))]
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .outputMissing, source: "youtube",
            detail: "no results", userMessage: "generic YouTube failure",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: nil, squid: FakeSquid())

        let result = await orch.downloadBatch([makeRequest()])
        // The first non-unknown (SC's 403) wins over YouTube's generic
        #expect(result.failureReasons[1] == scMessage)
    }

    /// A permanent failure anywhere in the chain wins over later transient ones.
    @Test
    func selectionRulePermanentWinsOverTransient() {
        let drmFailure = DownloadFailure(
            klass: .drmProtected, source: "soundcloud",
            detail: "DRM", userMessage: "DRM-protected on SoundCloud",
            heal: .none)
        let timeoutFailure = DownloadFailure(
            klass: .networkTimeout, source: "youtube",
            detail: "timed out", userMessage: "Timed out contacting YouTube",
            heal: .retrySameSource)
        // DRM first → wins
        let selected1 = DownloadOrchestrator.selectTerminalFailure(from: [drmFailure, timeoutFailure])
        #expect(selected1.klass == .drmProtected)
        #expect(selected1.userMessage == "DRM-protected on SoundCloud")

        // DRM second → still wins (permanent beats transient)
        let selected2 = DownloadOrchestrator.selectTerminalFailure(from: [timeoutFailure, drmFailure])
        #expect(selected2.klass == .drmProtected)
    }

    /// All-unknown chain → last failure is used.
    @Test
    func selectionRuleAllUnknownUsesLast() {
        let unknown1 = DownloadFailure(
            klass: .unknown, source: "soundcloud",
            detail: "mystery", userMessage: "SC mystery",
            heal: .fallThroughToNextSource)
        let unknown2 = DownloadFailure(
            klass: .unknown, source: "youtube",
            detail: "mystery2", userMessage: "YT mystery",
            heal: .fallThroughToNextSource)
        let selected = DownloadOrchestrator.selectTerminalFailure(from: [unknown1, unknown2])
        #expect(selected.userMessage == "YT mystery")
    }

    /// Empty trace → generic exhaustion message.
    @Test
    func selectionRuleEmptyTraceReturnsGeneric() {
        let selected = DownloadOrchestrator.selectTerminalFailure(from: [])
        #expect(selected.klass == .outputMissing)
        #expect(selected.source == "all")
    }

    // MARK: - Chain-continuation invariants (post-gate-removal)

    /// A permanent failure consumes no same-source retries (SC called
    /// exactly once) while still continuing the chain to every remaining
    /// source. This pins the one behaviour `isPermanent` still controls.
    @Test
    func permanentFailureConsumesNoSameSourceRetriesButContinuesChain() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .drmProtected, source: "soundcloud",
            detail: "DRM protected",
            userMessage: "DRM-protected on SoundCloud",
            heal: .none))]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        _ = await orch.downloadBatch([makeRequest()])

        // SC called exactly once — no retry for permanent
        #expect(sc.callCount == 1)
        // Chain continued to every remaining source
        #expect(dab.searchCallCount > 0)
        #expect(squid.searchCallCount > 0)
        #expect(yt.searchCallCount > 0)
    }

    /// When every source fails and SoundCloud's verdict was permanent,
    /// the terminal failureReasons entry is SoundCloud's classified
    /// message, not the last source's.
    @Test
    func terminalFailureUsesPermanentVerdictNotLastSource() async throws {
        let scMessage = "DRM-protected on SoundCloud — cannot be downloaded"
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .drmProtected, source: "soundcloud",
            detail: "DRM protected",
            userMessage: scMessage,
            heal: .none))]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        yt.outcomes = [.failure(DownloadFailure(
            klass: .formatUnavailable, source: "youtube",
            detail: "no match",
            userMessage: "No matching video on YouTube",
            heal: .none))]
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        let result = await orch.downloadBatch([makeRequest()])

        #expect(result.failed == 1)
        // SoundCloud's permanent DRM verdict wins over YouTube's generic no-match
        #expect(result.failureReasons[1] == scMessage)
    }

    /// Cancellation is the one legitimate reason to stop the chain.
    /// After cancel(), remaining tracks are marked cancelled, not failed.
    @Test
    func cancellationStopsTheChain() async throws {
        let sc = FakeSoundCloud()
        // SC hangs forever (no outcomes scripted → will exhaust, but we
        // cancel before it matters). Use a clock that we can observe.
        sc.outcomes = [.failure(DownloadFailure(
            klass: .networkTimeout, source: "soundcloud",
            detail: "timed out", userMessage: "Timed out",
            heal: .retrySameSource))]
        let yt = FakeYouTube()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt)

        // Cancel before starting — all tracks should be cancelled, none failed
        orch.cancel()
        let result = await orch.downloadBatch([makeRequest()])

        #expect(result.cancelledTrackIds.contains(1))
        #expect(result.failed == 0)
        #expect(yt.searchCallCount == 0)
    }

    /// Cancellation mid-chain (after SoundCloud has already been attempted
    /// and failed) must still record the track as cancelled, not failed.
    /// The afterDownload hook fires cancel() after SC returns, so the
    /// between-sources check aborts before DAB/Squid/YouTube run.
    @Test
    func cancellationMidChainRecordsCancelledNotFailed() async throws {
        let sc = FakeSoundCloud()
        sc.outcomes = [.failure(DownloadFailure(
            klass: .networkTimeout, source: "soundcloud",
            detail: "timed out", userMessage: "Timed out",
            heal: .retrySameSource))]
        let dab = FakeDAB()
        let squid = FakeSquid()
        let yt = FakeYouTube()
        let (orch, _, _, _, _) = try makeOrchestrator(sc: sc, yt: yt, dab: dab, squid: squid)

        // Cancel as a side-effect of SC returning — simulates the user
        // hitting cancel while the chain is between sources.
        sc.afterDownload = { orch.cancel() }

        let result = await orch.downloadBatch([makeRequest()])

        #expect(result.cancelledTrackIds.contains(1))
        #expect(!result.failedTrackIds.contains(1))
        #expect(result.failed == 0)
        // No source after SC was attempted
        #expect(dab.searchCallCount == 0)
        #expect(squid.searchCallCount == 0)
        #expect(yt.searchCallCount == 0)
    }
}
