import Foundation
import GRDB
import Testing
@testable import MLM

// MARK: - Words

@Suite("ReviewPresentationTests")
struct ReviewPresentationTests {
    private func track(_ id: Int64, format: String, bitrate: Int?, path: String? = "A/x") -> Track {
        var track = Track(artist: "Overmono", album: "Good Lies", title: "So U Kno", format: format, originalPath: "/x")
        track.id = id
        track.bitrate = bitrate
        track.organizedPath = path
        return track
    }

    private func group(_ members: [Track], recommended: Int64, keepAll: Bool = false) -> ReviewGroupItem {
        ReviewGroupItem(key: "k", kind: .duplicate, members: members, recommendedID: recommended, recommendsKeepAll: keepAll,
                        why: "lossless format", matchPercent: 97, usedIn: [:])
    }

    @Test func versionWordsNameWhyInsteadOfColour() {
        let flac = track(1, format: "flac", bitrate: 1411)
        let mp3 = track(2, format: "mp3", bitrate: 320)
        let same = track(3, format: "flac", bitrate: 1411)
        let missing = track(4, format: "mp3", bitrate: 320, path: nil)
        let g = group([flac, mp3, same, missing], recommended: 1)
        #expect(ReviewPresentation.versionLabel(for: flac, in: g) == "Recommended — lossless format")
        #expect(ReviewPresentation.versionLabel(for: mp3, in: g) == "Lower bitrate")
        #expect(ReviewPresentation.versionLabel(for: same, in: g) == "Same quality")
        #expect(ReviewPresentation.versionLabel(for: missing, in: g) == "Not downloaded")
    }

    @Test func aKeepAllRecommendationMarksNoVersionRecommended() {
        let flac = track(1, format: "flac", bitrate: 1411)
        let g = group([flac, track(2, format: "mp3", bitrate: 320)], recommended: 1, keepAll: true)
        #expect(ReviewPresentation.versionLabel(for: flac, in: g) == "Alternative")
        #expect(ReviewPresentation.recommendation(for: g) == "Keep all versions — probably different versions")
    }

    @Test func theRecommendationNamesFormatAndBitrateNeverArtistAndTitle() {
        let g = group([track(1, format: "flac", bitrate: 1411), track(2, format: "mp3", bitrate: 320)], recommended: 1)
        let text = ReviewPresentation.recommendation(for: g)
        #expect(text == "Keep FLAC · \(1411.formatted(.number)) kbps — lossless format")
        #expect(!text.contains("Overmono") && !text.contains("So U Kno"))
        #expect(g.headline == "2 versions of “So U Kno”")
    }

    @Test func consequenceSentencesAreTheMockupsVerbatim() {
        #expect(ReviewPresentation.consequenceSentence(.hidden)
            == "Versions you don’t keep stay on disk and in the library but no longer appear in All Tracks, albums or search. Playlists and sync profiles are re-pointed to the kept version.")
        #expect(ReviewPresentation.consequenceSentence(.trash)
            == "Files of versions you don’t keep are moved to the Trash (you can put them back from there). Playlists and sync profiles are re-pointed to the kept version.")
        #expect(ReviewPresentation.groupConsequence(others: 1, playlistEntries: 3, mode: .hidden)
            == "1 other version stays in the library, hidden from lists · 3 playlist entries are re-pointed to the kept version")
        #expect(ReviewPresentation.groupConsequence(others: 2, playlistEntries: 0, mode: .trash) == "2 other versions move to the Trash")
    }

    @Test func applyAllAlertWords() {
        #expect(ReviewPresentation.applyAllTitle(groups: 14) == "Keep the recommended version in 14 groups?")
        #expect(ReviewPresentation.applyAllButton(groups: 14) == "Keep Recommended in 14 Groups")
        #expect(ReviewPresentation.applyAllMessage(others: 20, playlistEntries: 6, mode: .hidden)
            == "20 other versions stay in the library, hidden from lists. 6 playlist entries are re-pointed to the kept versions. You can undo this in one step, or restore single groups in Resolved.")
        #expect(ReviewPresentation.applyAllMessage(others: 20, playlistEntries: 6, mode: .trash).hasPrefix("20 files of the other versions are moved to the Trash."))
    }

    @Test func outcomesOfEveryDecision() {
        func record(_ action: ReviewDecisionAction, mode: UnkeptMode? = nil, _ edit: (inout ReviewDecisionConsequences) -> Void = { _ in }) -> ReviewDecisionRecord {
            var consequences = ReviewDecisionConsequences()
            edit(&consequences)
            return ReviewDecisionRecord(id: 1, groupKey: "k", kind: .duplicate, action: action, keptTrackID: 1, unkeptMode: mode,
                                        consequences: consequences, decidedAt: "2026-10-03T17:02:00Z")
        }
        #expect(ReviewPresentation.outcome(record(.keepRecommended, mode: .hidden) {
            $0.keptFormat = "flac"; $0.hiddenCount = 2
            $0.playlistRows = (0..<3).map { _ in .init(id: 1, playlistId: 1, trackId: 1, position: "a", addedAt: nil, change: .repointed) }
        }) == "FLAC kept · 2 versions hidden from lists · 3 playlist entries re-pointed")
        #expect(ReviewPresentation.outcome(record(.keepSelected, mode: .trash) { $0.keptFormat = "m4a"; $0.hiddenCount = 1 })
            == "M4A kept · 1 version moved to the Trash")
        #expect(ReviewPresentation.outcome(record(.keepAll)) == "Nothing changed · not proposed again")
        #expect(ReviewPresentation.outcome(record(.merge) {
            $0.changedFields = ["Album", "Year"]
            $0.tags = [.init(trackId: 1, field: "album", old: .text("a")), .init(trackId: 2, field: "album", old: .text("b"))]
        }) == "2 files updated: Album, Year")
    }

    @Test func trashWordsAreExact() {
        #expect(ReviewPresentation.couldntTrash(3) == "Couldn’t move 3 files to the Trash")
        #expect(ReviewPresentation.couldntTrash(1) == "Couldn’t move 1 file to the Trash")
        #expect(ReviewPresentation.cantUndoTrash(2) == "Can’t undo the Trash move — 2 files are no longer in the Trash")
    }

    @Test func conflictFieldsFindWhatDiffers() {
        var a = track(1, format: "flac", bitrate: nil)
        var b = track(2, format: "mp3", bitrate: nil)
        a.year = 2019
        b.year = nil
        b.genre = "Techno"
        #expect(ConflictField.differing(in: [a, b]) == [.genre, .year])
        #expect(ConflictField.year.value(from: "2020") == .number(2020))
        #expect(ConflictField.genre.value(from: "") == .text(nil))
    }
}

// MARK: - Trash (injectable file system)

@Suite("ReviewConsequencesTests")
struct ReviewConsequencesTests {
    @Test func relativeAndAbsolutePathsResolve() {
        #expect(ReviewConsequences.fileURL(organizedPath: "A/B.flac", libraryRoot: "/lib")?.path == "/lib/A/B.flac")
        #expect(ReviewConsequences.fileURL(organizedPath: "/Volumes/X/B.flac", libraryRoot: nil)?.path == "/Volumes/X/B.flac")
        #expect(ReviewConsequences.fileURL(organizedPath: "A/B.flac", libraryRoot: nil) == nil)
        #expect(ReviewConsequences.fileURL(organizedPath: nil, libraryRoot: "/lib") == nil)
    }

    @Test func eachFileIsItsOwnTryAndFailuresAreCounted() {
        let files = FakeReviewFiles(existing: ["/lib/a.mp3", "/lib/b.mp3"])
        files.failing = ["/lib/b.mp3"]
        let report = ReviewConsequences(files: files).trash([
            (1, URL(fileURLWithPath: "/lib/a.mp3")), (2, URL(fileURLWithPath: "/lib/b.mp3")),
            (3, URL(fileURLWithPath: "/lib/gone.mp3")), (4, nil),
        ])
        #expect(report.trashed.map(\.trackId) == [1])
        #expect(report.failures == 1, "a file that is already gone or has no path is not a failure")
        #expect(report.trashed.first?.trashURL == "/Trash/a.mp3")
    }

    @Test func putBackReportsWhatIsNoLongerInTheTrash() {
        let files = FakeReviewFiles(existing: ["/lib/a.mp3", "/lib/b.mp3"])
        let consequences = ReviewConsequences(files: files)
        let report = consequences.trash([(1, URL(fileURLWithPath: "/lib/a.mp3")), (2, URL(fileURLWithPath: "/lib/b.mp3"))])
        files.removeFromTrash("b.mp3")
        let back = consequences.putBack(report.trashed)
        #expect(back.restored == 1)
        #expect(back.gone == 1)
        #expect(files.fileExists(atPath: "/lib/a.mp3"))
    }

    @Test func aTakenOriginalPlaceIsNotOverwritten() {
        let files = FakeReviewFiles(existing: ["/lib/a.mp3"])
        let consequences = ReviewConsequences(files: files)
        let report = consequences.trash([(1, URL(fileURLWithPath: "/lib/a.mp3"))])
        _ = files.fileExists(atPath: "/lib/a.mp3")
        // Something else was put at the original place meanwhile.
        try? files.moveBack(from: URL(fileURLWithPath: "/nowhere"), to: URL(fileURLWithPath: "/lib/a.mp3"))
        #expect(consequences.putBack(report.trashed).gone == 1)
    }

    @Test func theSystemFileManagerMovesWithinATemporaryFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("from/a.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let manager = SystemReviewFileManager()
        let destination = folder.appendingPathComponent("to/deeper/a.txt")
        try manager.moveBack(from: source, to: destination)
        #expect(manager.fileExists(atPath: destination.path))
        #expect(!manager.fileExists(atPath: source.path))
    }
}

// MARK: - The scan as an Activity operation

@Suite("ReviewScanRunnerTests", .serialized)
@MainActor
struct ReviewScanRunnerTests {
    /// Lets a test hold the scan open and release it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume() } else { self.continuation = continuation; lock.unlock() }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private func waitFor(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(description)")
    }

    private func make(gate: Gate, result: DeepScanService.DeepScanResult = .init(pairsCompared: 10, duplicatesFound: 4, conflictsFlagged: 2),
                      error: (any Error)? = nil) throws -> (ReviewEnv, ReviewScanRunner) {
        let env = try ReviewEnv.make()
        let runner = ReviewScanRunner(center: env.center, config: { env.config }, scan: {
            { progress in
                progress(3, 10)
                await gate.wait()
                if let error { throw error }
                return result
            }
        }, didChange: {})
        return (env, runner)
    }

    @Test func theHeaderEchoesTheOperationInItsWords() async throws {
        let gate = Gate()
        let (env, runner) = try make(gate: gate)
        let model = ReviewModel(dependencies: env.model.dependencies, scan: runner, center: env.center)
        #expect(model.scanEcho == nil)
        #expect(runner.start())
        try await waitFor("the echo") { model.scanEcho?.progressText != nil }
        let echo = try #require(model.scanEcho)
        let operation = try #require(env.center.activeOperations.first { $0.kind == .duplicateScan })
        #expect(echo.operationID == operation.id)
        #expect(echo.toolbarText == "Comparing \(4.formatted(.number)) of \(10.formatted(.number))", "the same words and numbers as Activity")
        #expect(echo.toolbarText == env.center.echo(for: .review)?.toolbarText)
        #expect(operation.subject == .review)
        gate.release()
        await runner.waitUntilIdle()
        #expect(model.scanEcho == nil)
    }

    @Test func aSecondStartWhileRunningDoesNothing() async throws {
        let gate = Gate()
        let (env, runner) = try make(gate: gate)
        #expect(runner.start())
        #expect(!runner.start())
        #expect(runner.blockedReason == "A scan is running — see Activity.")
        gate.release()
        await runner.waitUntilIdle()
        #expect(runner.blockedReason == nil)
        #expect(env.center.finishedOperations.filter { $0.kind == .duplicateScan }.count == 1)
    }

    @Test func aFinishedScanPersistsItsLastScanLine() async throws {
        let gate = Gate()
        let (env, runner) = try make(gate: gate)
        gate.release()
        runner.start()
        await runner.waitUntilIdle()
        #expect(runner.lastScan?.comparisons == 10)
        #expect(runner.lastScan?.duplicateGroups == 4)
        #expect(runner.lastScan?.conflicts == 2)
        let reloaded = await ReviewLastScan.load(from: env.config)
        #expect(reloaded == runner.lastScan, "persisted in app_config (review.lastScan.*)")
        #expect(try await env.config.get(key: ReviewLastScan.keyGroups) == "4")
        let finished = try #require(env.center.finishedOperations.first { $0.kind == .duplicateScan })
        #expect(finished.result?.sentence == "4 duplicate groups · 2 conflicts")
    }

    @Test func aFailedScanSaysSoAndKeepsTheGroups() async throws {
        let gate = Gate()
        let (env, runner) = try make(gate: gate, error: CocoaError(.fileReadUnknown))
        gate.release()
        runner.start()
        await runner.waitUntilIdle()
        #expect(runner.failure?.headline == "The last scan didn’t finish.")
        #expect(runner.failure?.details.isEmpty == false)
        #expect(runner.lastScan == nil)
        #expect(env.center.finishedOperations.first { $0.kind == .duplicateScan }?.state == .failed)
    }

    @Test func cancelEndsTheOperationAsCancelled() async throws {
        let gate = Gate()
        let (env, runner) = try make(gate: gate)
        runner.start()
        try await waitFor("the scan to run") { env.center.activeOperations.contains { $0.kind == .duplicateScan } }
        runner.cancel()
        gate.release()
        await runner.waitUntilIdle()
        #expect(env.center.finishedOperations.first { $0.kind == .duplicateScan }?.state == .cancelled)
        #expect(runner.lastScan == nil)
    }
}

// MARK: - Hidden from lists (IMP-049)

@Suite("TrackVisibilityTests")
struct TrackVisibilityTests {
    private func seed(_ db: DatabaseQueue) throws {
        try db.write { db in
            for index in 0..<3 {
                var track = Track(artist: "Overmono", album: "Good Lies", title: "So U Kno \(index)", format: "mp3", originalPath: "/\(index).mp3")
                track.organizedPath = "A/\(index).mp3"
                track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
                try track.insert(db)
            }
            try db.execute(sql: "UPDATE tracks SET is_duplicate = 1, hidden_by_review = 1 WHERE id = 3")
        }
    }

    @Test func aHiddenVersionLeavesAllTracksRowsCountsAndSearch() async throws {
        let db = try DatabaseManager.inMemory()
        try seed(db)
        let rows = try await TrackRepository(database: db).fetchTracks(scope: .all)
        #expect(rows.compactMap(\.id) == [1, 2])
        let summary = try await TrackScopeQueries(database: db).scopeSummary()
        #expect(summary.counts.all == 2, "counts follow the rows")
        #expect(summary.libraryCount == 3, "it is still in the library")
        let searched = try await TrackSearchQueries(database: db).fetchTracks(scope: .all, filter: SearchFilter(text: "kno"))
        #expect(searched.compactMap(\.id) == [1, 2])
        let matching = try await TrackSearchQueries(database: db).matchingTracks(filter: SearchFilter(text: "kno"), limit: 10)
        #expect(matching.total == 2)
        let withSummary = try await TrackSearchQueries(database: db).scopeSummary(filter: SearchFilter(text: "kno"))
        #expect(withSummary.counts.all == 2)
    }

    @Test func anOldDuplicateFlagAloneHidesNothing() async throws {
        let db = try DatabaseManager.inMemory()
        try seed(db)
        try await db.write { db in try db.execute(sql: "UPDATE tracks SET is_duplicate = 1 WHERE id = 1") }
        let rows = try await TrackRepository(database: db).fetchTracks(scope: .all)
        #expect(rows.compactMap(\.id) == [1, 2])
    }

    @Test func otherListsAreUnchanged() async throws {
        let db = try DatabaseManager.inMemory()
        try seed(db)
        let playlist = try ReviewDecisionRepositoryTests.addPlaylist(db, name: "Warm-up", tracks: [3])
        let inPlaylist = try await db.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlist])
        }
        #expect(inPlaylist == [3], "playlists, genres, folders, queue and sync keep it (IMP-049)")
        #expect(TrackVisibility.listedSQL == "tracks.hidden_by_review = 0")
    }
}

// MARK: - Rules of the code

@Suite("ReviewSourceRulesTests")
struct ReviewSourceRulesTests {
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MLM/Views/Review", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func noMlmTokensToastsOrOldVocabularyRemain() throws {
        for (name, text) in try sources() {
            #expect(text.range(of: #"\bmlm[A-Z]\w*"#, options: .regularExpression) == nil, "\(name): no mlm* colour or font token (UC-COLOR)")
            #expect(!text.contains("Toast") && !text.contains("toast"), "\(name): confirmations go to the status bar")
            #expect(!text.contains("Keep all\"") && !text.contains("Keep all ") && !text.contains("Never suggest again"), "\(name): old vocabulary")
            #expect(!text.contains("#available"), "\(name): macOS 27 only")
            #expect(!text.contains("Color(red") && !text.contains("Color(hex") && !text.contains(".custom("), "\(name): system colours and fonts")
        }
    }

    @Test func theOldFilesAreGone() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MLM/Views/ReviewQueue/ReviewQueueView.swift").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MLM/ViewModels/ReviewQueueViewModel.swift").path))
    }
}
