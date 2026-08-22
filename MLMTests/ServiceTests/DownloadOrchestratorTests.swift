import Foundation
import Testing
@testable import MLM

/// Tests for the DownloadOrchestrator public surface.
///
/// The internal chain (SoundCloud -> DAB -> YouTube -> Transcode) calls
/// real network/CLI binaries, so these tests focus on:
/// - Initialization leaves managed directories absent until a download needs one.
/// - Empty batches return a clean BatchResult.
/// - cancel() stops a batch before the first request starts.
/// - Legacy staging files never masquerade as completed downloads.
struct DownloadOrchestratorTests {

    private func makeTempLibrary() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_download_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

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

        let orchestrator = DownloadOrchestrator(
            libraryRoot: root.path,
            tokenStorage: TokenStorage()
        )
        let result = await orchestrator.downloadBatch([])

        #expect(result.succeeded == 0)
        #expect(result.failed == 0)
        #expect(result.skipped == 0)
        #expect(result.downloadedPaths.isEmpty)
        #expect(result.downloadedMetadata.isEmpty)
    }

    /// A legacy file in the staging directory is not a completed download.
    /// Final output is source-routed and includes the track ID, so it cannot
    /// silently reuse the ambiguous pre-SCDL-09 filename.
    @Test
    func legacyFlacStagingDoesNotMasqueradeAsCompletedDownload() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let orchestrator = DownloadOrchestrator(
            libraryRoot: root.path,
            tokenStorage: TokenStorage()
        )

        let flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        try FileManager.default.createDirectory(at: flacDir, withIntermediateDirectories: true)
        let preExisting = flacDir.appendingPathComponent("Yeat - Mr. Lordbow.flac")
        FileManager.default.createFile(atPath: preExisting.path, contents: Data("fake".utf8))

        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 42,
            artist: "Yeat",
            title: "Mr. Lordbow",
            query: "Yeat - Mr. Lordbow",
            soundcloudURL: nil,
            userId: nil
        )

        #expect(FileManager.default.fileExists(atPath: preExisting.path))
        #expect(orchestrator.finalDirectory(for: .youtube).standardizedFileURL != flacDir.standardizedFileURL)
        #expect(
            DownloadOrchestrator.finalFileName(for: request, pathExtension: "flac")
                != preExisting.lastPathComponent
        )
    }

    /// `cancel()` should be a no-op when called on an idle orchestrator
    /// and must not crash. The next `downloadBatch` call clears the
    /// flag, so the orchestrator never gets stuck in a cancelled state.
    @Test
    func cancelIsSafeOnIdleOrchestrator() async throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let orchestrator = DownloadOrchestrator(
            libraryRoot: root.path,
            tokenStorage: TokenStorage()
        )

        // Call cancel() with no batch in flight — must not crash.
        orchestrator.cancel()
        orchestrator.cancel()

        // The next batch resets the flag at entry and runs to completion.
        // Use an empty batch so we don't try to hit any downloaders.
        let result = await orchestrator.downloadBatch([])
        #expect(result.succeeded == 0)
        #expect(result.failed == 0)
        #expect(orchestrator.isRunning == false)
    }

    /// Verify that downloadedMetadata carries the format and bitrate the
    /// DB write needs. We assert the type shape, not specific values
    /// (since asserting actual downloads would require network access).
    @Test
    func downloadedFileInfoCarriesFormatAndBitrate() {
        let info = DownloadOrchestrator.DownloadedFileInfo(format: "m4a", bitrate: 248)
        #expect(info.format == "m4a")
        #expect(info.bitrate == 248)

        let infoNoBitrate = DownloadOrchestrator.DownloadedFileInfo(format: "mp3", bitrate: nil)
        #expect(infoNoBitrate.format == "mp3")
        #expect(infoNoBitrate.bitrate == nil)
    }

    // MARK: - Download failure reason classification

    @Test
    func failureReasonsUseBoundedPlainLanguageVocabulary() {
        let ytDlpUnavailable = NSError(
            domain: "Download",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "yt-dlp not installed"]
        )
        let unavailableVideo = NSError(
            domain: "Download",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Video unavailable"]
        )

        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(for: ytDlpUnavailable)
                == .ytDlpUnavailable
        )
        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(for: unavailableVideo)
                == .videoUnavailable
        )
        #expect(
            DownloadOrchestrator.DownloadFailureReason.failureReason(
                for: URLError(.notConnectedToInternet)
            ) == .network
        )
        #expect(DownloadOrchestrator.DownloadFailureReason.network.userFacingText == "Network error")
        #expect(
            DownloadOrchestrator.failureReasonForExhaustedSources(
                preferredSource: .youtube,
                youtubeAvailable: true
            ) == .sourcesExhausted
        )
        #expect(
            DownloadOrchestrator.failureReasonForExhaustedSources(
                preferredSource: .youtube,
                youtubeAvailable: false
            ) == .ytDlpUnavailable
        )
    }

    // MARK: - Task 1: PreferredSource storageKey round-trip (SCDL-01)

    /// ROUND-TRIP LAW: every case must decode back to itself through its
    /// own persisted storage key. This is the load-bearing guarantee that
    /// makes the retry-queue pin trustworthy.
    @Test
    func preferredSourceStorageKeyRoundTripsForEveryCase() {
        let allCases: [DownloadOrchestrator.PreferredSource] = [.auto, .soundcloud, .youtube]
        for source in allCases {
            #expect(DownloadOrchestrator.PreferredSource(storageKey: source.storageKey) == source)
        }
    }

    /// The storage keys themselves are pinned strings — a future rename of
    /// the enum cases must not silently change what's persisted to disk.
    @Test
    func preferredSourceStorageKeysAreStable() {
        #expect(DownloadOrchestrator.PreferredSource.auto.storageKey == "auto")
        #expect(DownloadOrchestrator.PreferredSource.soundcloud.storageKey == "soundcloud")
        #expect(DownloadOrchestrator.PreferredSource.youtube.storageKey == "youtube")
    }

    /// `nil` (legacy queue item, key never written) and any unrecognized
    /// string must fail safe to `.auto` — never crash, never escalate an
    /// unknown key to a stronger pin than the caller can prove.
    @Test
    func preferredSourceFailsSafeToAutoForNilOrUnknownKey() {
        #expect(DownloadOrchestrator.PreferredSource(storageKey: nil) == .auto)
        #expect(DownloadOrchestrator.PreferredSource(storageKey: "garbage") == .auto)
    }

    /// A `.retry_queue.json` written by the previous app version (missing
    /// `preferred_source`/`soundcloud_url`) must decode without throwing,
    /// with the new fields defaulting to nil.
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
        // And the fail-safe rebuild from a missing key is .auto, not a crash.
        #expect(DownloadOrchestrator.PreferredSource(storageKey: decoded[0].preferredSource) == .auto)
    }

    /// The same legacy JSON, written to disk as an actual
    /// `.retry_queue.json` file and loaded through `DownloadQueue`'s normal
    /// file-based `load()`, must not crash the app on launch.
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

    /// QueueItem round-trip through disk: enqueue with a SoundCloud pin +
    /// URL, reload via a fresh `DownloadQueue` pointed at the same
    /// directory, and the item still reports the pin + URL.
    @Test
    func queueItemRoundTripsPreferredSourceAndSoundcloudURL() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = DownloadQueue(directory: tmp)
        queue.enqueue(
            trackId: 9,
            query: "Artist - Title",
            source: "soundcloud",
            error: "network hiccup",
            artist: "Artist",
            title: "Title",
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

    /// `enqueue` must record the ACTUAL attempted source, not a hardcoded
    /// literal — an item enqueued as "soundcloud" must still read back as
    /// "soundcloud", not "youtube".
    @Test
    func enqueueRecordsActualAttemptedSourceNotHardcodedLiteral() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = DownloadQueue(directory: tmp)
        queue.enqueue(trackId: 1, query: "Artist - Title", source: "soundcloud", error: "e")

        let item = try #require(queue.items.first)
        #expect(item.source == "soundcloud")
    }

    // MARK: - Task 2: retryFailed preserves the pin (SCDL-01)

    /// After enqueuing a SoundCloud-pinned failure, the reconstructed
    /// PreferredSource (the exact mapping `retryFailed()` uses) must still
    /// be `.soundcloud` — proving a pinned retry cannot silently degrade to
    /// `.auto` and run the full cross-provider chain.
    @Test
    func soundCloudPinnedFailureSurvivesRetryQueueRoundTrip() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = DownloadQueue(directory: tmp)
        queue.enqueue(
            trackId: 77,
            query: "Artist - Title",
            source: DownloadOrchestrator.PreferredSource.soundcloud.storageKey,
            error: "scdl timed out",
            preferredSource: DownloadOrchestrator.PreferredSource.soundcloud.storageKey,
            soundcloudURL: "https://soundcloud.com/artist/pinned-track"
        )

        let retryable = queue.retryableItems()
        #expect(retryable.count == 1)
        let item = try #require(retryable.first)

        // This is exactly the mapping `retryFailed()` performs when
        // rebuilding each DownloadRequest.
        let rebuiltPin = DownloadOrchestrator.PreferredSource(storageKey: item.preferredSource)
        #expect(rebuiltPin == .soundcloud)
        #expect(item.soundcloudURL == "https://soundcloud.com/artist/pinned-track")
    }

    @Test
    func legacyRetryQueryRecoversArtistAndFullTitle() {
        let identity = DownloadOrchestrator.parseIdentity(
            from: "Artist - Title - Extended Mix"
        )
        #expect(identity.artist == "Artist")
        #expect(identity.title == "Title - Extended Mix")
    }

    @Test
    func dequeuePersistedRetriesRemovesOnlySuccessfulTracks() throws {
        let tmp = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = DownloadQueue(directory: tmp)
        queue.enqueue(trackId: 1, query: "A - One", source: "soundcloud", error: "e")
        queue.enqueue(trackId: 2, query: "A - Two", source: "soundcloud", error: "e")

        queue.dequeue(trackIds: [1])

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
            queue.enqueue(
                trackId: 88,
                query: "Artist - Capped Failure",
                source: "youtube",
                error: "Video unavailable",
                artist: "Artist",
                title: "Capped Failure"
            )
        }

        let reloadedQueue = DownloadQueue(directory: queueDirectory)
        #expect(reloadedQueue.items.count == 1)
        #expect(reloadedQueue.items.first?.attemptCount == 3)
        #expect(reloadedQueue.retryableItems().isEmpty)

        let reloadedOrchestrator = DownloadOrchestrator(
            libraryRoot: root.path,
            tokenStorage: TokenStorage()
        )
        let activityItems = reloadedOrchestrator.persistedRetryItems()
        #expect(activityItems.count == 1)
        #expect(activityItems.first?.trackId == 88)
        #expect(activityItems.first?.lastError == "Video unavailable")
    }

    // MARK: - Task 4: finalDirectory / preservesOriginal / placeFinal / finalize (SCDL-09)

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
            trackId: 10,
            artist: "Artist",
            title: "Same Title",
            query: "Artist - Same Title",
            soundcloudURL: nil,
            userId: nil
        )
        let second = DownloadOrchestrator.DownloadRequest(
            trackId: 11,
            artist: "Artist",
            title: "Same Title",
            query: "Artist - Same Title",
            soundcloudURL: nil,
            userId: nil
        )

        let firstName = DownloadOrchestrator.finalFileName(
            for: first,
            pathExtension: "m4a"
        )
        let secondName = DownloadOrchestrator.finalFileName(
            for: second,
            pathExtension: "m4a"
        )

        #expect(firstName != secondName)
        #expect(firstName.hasSuffix("[10].m4a"))
        #expect(secondName.hasSuffix("[11].m4a"))
    }

    /// MOVE: given a temp file, placeFinal moves it into the final dir and
    /// removes the temp source.
    @Test
    func placeFinalMovesTempFileIntoFinalDirectory() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let finalDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)

        let tempFile = root.appendingPathComponent("scratch-temp.m4a")
        try Data("new bytes".utf8).write(to: tempFile)

        let dest = try orchestrator.placeFinal(tempFile, into: finalDir)

        #expect(dest.standardizedFileURL == finalDir.appendingPathComponent("scratch-temp.m4a").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
    }

    /// COLLISION/REPLACE: pre-create a file with the same basename in the
    /// final dir; placeFinal still succeeds, exactly ONE file with that
    /// name remains, and its contents are the new (transcoded) bytes.
    @Test
    func placeFinalReplacesCollidingFileWithNewContent() throws {
        let root = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let orchestrator = DownloadOrchestrator(libraryRoot: root.path, tokenStorage: TokenStorage())
        let finalDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)

        let existing = finalDir.appendingPathComponent("collide.m4a")
        try Data("old bytes".utf8).write(to: existing)

        // The "produced" temp file must share the final basename to
        // exercise the collision path.
        let producedTemp = root.appendingPathComponent("collide.m4a")
        try Data("new bytes".utf8).write(to: producedTemp)

        let dest = try orchestrator.placeFinal(producedTemp, into: finalDir)

        let matches = try FileManager.default
            .contentsOfDirectory(at: finalDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "collide.m4a" }
        #expect(matches.count == 1)
        #expect(try Data(contentsOf: dest) == Data("new bytes".utf8))
    }

    /// FINAL-PATH-PARENT (ffmpeg-independent): a fake (non-audio) `.m4a`
    /// deterministically fails/gets-skipped by TranscodeService, so the
    /// source itself is kept as the final file. Assert its parent
    /// directory is `soundCloudDir` for a `.soundcloud` source.
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
            trackId: 100,
            artist: "A",
            title: "B",
            query: "A - B",
            soundcloudURL: "https://soundcloud.com/a/b",
            userId: nil
        )

        let finalized = try await orchestrator.finalize(sourcePath: fakeFile, source: .soundcloud, request: request)

        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL == soundCloudDir.standardizedFileURL)
    }

    /// Same FINAL-PATH-PARENT proof for `.youtube`: parent must be `aacDir`
    /// and must NOT be `flacDir` (Transcode originals).
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
            trackId: 101,
            artist: "A",
            title: "B",
            query: "A - B",
            soundcloudURL: nil,
            userId: nil
        )

        let finalized = try await orchestrator.finalize(sourcePath: fakeFile, source: .youtube, request: request)

        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL == aacDir.standardizedFileURL)
        #expect(finalized.path.deletingLastPathComponent().standardizedFileURL != flacDir.standardizedFileURL)
    }
}
