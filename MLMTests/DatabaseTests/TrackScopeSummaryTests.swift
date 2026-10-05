import Foundation
import GRDB
import Testing
@testable import MLM

/// The scoped SQL aggregates behind All Tracks' scope bar and status bar (W2-B, UC-TABLE-21,
/// UC-STATUS-02), on temporary in-memory databases only.
@Suite("TrackScopeSummaryTests")
struct TrackScopeSummaryTests {
    private static let failureJSON = try! TrackDownloadFailure(
        reason: "Timed out contacting SoundCloud", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 2
    ).encodedJSON()

    /// (organized_path, file_missing_since, download_status, download_failure, duration, title)
    private typealias Row = (String?, String?, String?, String?, Int?, String)

    private static let rows: [Row] = [
        ("A/1.m4a", nil, nil, nil, 200, "Glass Circuit"),             // local
        ("A/2.m4a", nil, "2026-01-01", nil, 300, "Warm Up"),           // local
        ("A/3.m4a", "2026-10-05T10:00:00Z", nil, nil, 400, "Lost"),    // file missing
        (nil, nil, nil, nil, 100, "Linked One"),                       // not downloaded
        (nil, nil, "remote", nil, nil, "Linked Two"),                   // not downloaded, no duration
        (nil, nil, "downloading", failureJSON, 50, "Retrying"),        // downloading → Not downloaded (IMP-021)
        (nil, nil, "failed", nil, 60, "Legacy Failure"),               // download failed
        (nil, nil, nil, failureJSON, 70, "Glass Failure"),             // download failed
        ("", nil, nil, nil, 80, "Empty Path"),                         // not downloaded
    ]

    private func makeDatabase(_ rows: [Row] = rows) async throws -> (DatabaseQueue, TrackRepository, TrackScopeQueries) {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        for (index, row) in rows.enumerated() {
            var track = Track(artist: "Artist \(index)", album: "Album", title: row.5, format: "m4a",
                              originalPath: "/orig/\(index).m4a")
            track.organizedPath = row.0
            track.downloadStatus = row.2
            track.downloadFailure = row.3
            track.duration = row.4
            let inserted = try await repo.insert(track)
            if let missing = row.1, let id = inserted.id {
                try await db.write { db in
                    try db.execute(sql: "UPDATE tracks SET file_missing_since = ? WHERE id = ?", arguments: [missing, id])
                }
            }
        }
        return (db, repo, TrackScopeQueries(database: db))
    }

    @Test func countsAndDurationsPerScope() async throws {
        let (_, _, queries) = try await makeDatabase()
        let summary = try await queries.scopeSummary()
        #expect(summary.libraryCount == 9)
        #expect(summary.counts.all == 9)
        #expect(summary.counts.local == 2)
        #expect(summary.counts.notDownloaded == 4)
        #expect(summary.counts.downloading == 1)
        #expect(summary.counts.failed == 2)
        #expect(summary.counts.fileMissing == 1)
        #expect(summary.durations[.all] == 1_260)
        #expect(summary.durations[.local] == 500)
        #expect(summary.durations[.notDownloaded] == 230)  // 100 + 0 (unknown) + 50 + 80
        #expect(summary.durations[.downloadFailed] == 130)
        #expect(summary.durations[.fileMissing] == 400)
        #expect(summary.totals(for: .downloadFailed) == TrackListTotals(count: 2, duration: 130))
    }

    /// The four scopes after `All` partition the library (IMP-021), and every scope's count is
    /// exactly the rows `fetchTracks(scope:)` returns — the table never disagrees with its bar.
    @Test func scopesPartitionTheLibraryAndMatchTheRows() async throws {
        let (_, repo, queries) = try await makeDatabase()
        for search in [nil, "glass", "linked", "zzz"] as [String?] {
            let summary = try await queries.scopeSummary(search: search)
            let counts = summary.counts
            #expect(counts.local + counts.notDownloaded + counts.failed + counts.fileMissing == counts.all,
                    "partition for \(search ?? "no search")")
            #expect(summary.libraryCount == 9)
            for scope in TrackAvailabilityScope.allCases {
                let rows = try await repo.fetchTracks(scope: scope, search: search)
                #expect(rows.count == counts.count(for: scope), "\(scope) for \(search ?? "no search")")
                #expect(rows.reduce(0) { $0 + ($1.duration ?? 0) } == summary.durations[scope], "\(scope) duration")
                #expect(rows.allSatisfy { scope.contains($0.availability()) }, "\(scope) rows")
            }
        }
    }

    @Test func countsFollowTheSearch() async throws {
        let (_, repo, queries) = try await makeDatabase()
        let summary = try await queries.scopeSummary(search: "glass")
        #expect(summary.counts.all == 2)
        #expect(summary.counts.local == 1)
        #expect(summary.counts.failed == 1)
        #expect(summary.libraryCount == 9, "the library size ignores the search")
        // Same terms rule as the rows and W2-A's counts: AND of folded terms.
        #expect(try await repo.availabilityCounts(search: "glass") == summary.counts)
        let none = try await queries.scopeSummary(search: "glass   warm")
        #expect(none.counts.all == 0)
        #expect(none.durations[.all] == 0)
    }

    @Test func emptyLibrary() async throws {
        let (_, _, queries) = try await makeDatabase([])
        let summary = try await queries.scopeSummary()
        #expect(summary.libraryCount == 0)
        #expect(summary.counts == TrackAvailabilityCounts())
        #expect(summary.totals(for: .all) == TrackListTotals(count: 0, duration: 0))
    }

    /// The status bar's default text from the scoped totals: `12,935 tracks · 38 days`.
    @Test func statusBarFormatsWithThousandsSeparators() {
        let totals = TrackScopeSummary(
            counts: TrackAvailabilityCounts(all: 12_935), durations: [.all: 38 * 86_400], libraryCount: 12_935
        ).totals(for: .all)
        let text = "\(StatusBarText.tracks(totals.count)) · \(TrackDurationText.total(totals.duration))"
        #expect(text == "\(12_935.formatted(.number)) tracks · 38 days")
        #expect(StatusBarText.tracks(1) == "1 track")
        #expect(TrackDurationText.total(52 * 60) == "52 min")
        #expect(TrackDurationText.total(171 * 60) == "2 h 51 min")
    }
}
