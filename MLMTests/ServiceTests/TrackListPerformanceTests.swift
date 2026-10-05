import Foundation
import GRDB
import Testing
@testable import MLM

/// 15,000 synthetic tracks in a temporary database: the track table's data path must stay
/// fast (W2-A). Bounds are generous so CI doesn't flake; the measured numbers are printed
/// (`PERF …`) for the report.
@Suite("TrackListPerformanceTests", .serialized)
@MainActor
struct TrackListPerformanceTests {
    static let trackCount = 15_000

    private static func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseManager.inMemory()
        let failure = try TrackDownloadFailure(reason: "Source timed out", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 1).encodedJSON()
        try db.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, genre, year, bitrate, duration, format,
                                    original_path, organized_path, is_duplicate, date_added, date_added_library,
                                    download_status, download_failure, energy_bucket, danceability, bpm,
                                    search_text, file_missing_since)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'm4a', ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for index in 0..<trackCount {
                let artist = "Artist \(index % 900)"
                let title = "Track \(String(index * 7919 % 100_003, radix: 36)) \(index)"
                let album = index % 2 == 0 ? "unknown album" : "Album \(index % 1600)"
                let local = index % 3 != 0
                let day = String(format: "2026-%02d-%02dT10:00:00Z", index % 12 + 1, index % 28 + 1)
                try statement.execute(arguments: [
                    artist, artist, album, title, "Genre \(index % 40)", 1990 + index % 35, 248, 120 + index % 400,
                    "/orig/\(index).m4a", local ? "Artist/\(index).m4a" : nil, day, local ? day : nil,
                    index % 30 == 3 ? "failed" : nil, index % 30 == 3 ? failure : nil,
                    index % 6 == 0 ? nil : index % 5 + 1, Double(index % 10) / 10, index % 7 == 0 ? nil : 90 + index % 60,
                    DatabaseManager.foldedSearchText("\(artist) \(album) \(title)"),
                    local && index % 97 == 0 ? "2026-10-05T10:00:00Z" : nil,
                ])
            }
        }
        return db
    }

    private static func measure<T>(_ label: String, _ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("PERF \(label): \(String(format: "%.1f", ms)) ms")
        return (value, ms)
    }

    @Test func fifteenThousandRowsStayFast() async throws {
        let db = try Self.makeDatabase()
        let repository = TrackRepository(database: db)

        let (tracks, fetchMS) = try await Self.measure("fetch 15k tracks (SQL)") {
            try await repository.fetchTracks(scope: .all)
        }
        #expect(tracks.count == Self.trackCount)
        #expect(fetchMS < 5_000)

        let (counts, countsMS) = try await Self.measure("availability aggregate (SQL)") {
            try await repository.availabilityCounts()
        }
        #expect(counts.all == Self.trackCount)
        #expect(counts.local + counts.notDownloaded + counts.failed + counts.fileMissing == Self.trackCount)
        #expect(countsMS < 2_000)

        let (rows, buildMS) = await Self.measure("row-model build") { TrackRowBuilder.build(tracks) }
        #expect(rows.count == Self.trackCount)
        #expect(buildMS < 4_000)

        var worstSort = 0.0
        for column in TrackColumnID.allCases {
            let (sorted, ms) = await Self.measure("sort by \(column.rawValue)") {
                TrackRowSorter.sorted(rows, by: TrackSortOrder(column: column, ascending: column == .title))
            }
            #expect(sorted.count == rows.count)
            worstSort = max(worstSort, ms)
        }
        print("PERF worst column sort: \(String(format: "%.1f", worstSort)) ms")
        #expect(worstSort < 3_000)

        // Model: load + sort + index off the main actor, then select-all and an arrow step.
        let model = TrackListModel(sortOrder: TrackSortOrder(column: .added, ascending: false))
        let (_, loadMS) = await Self.measure("model load (build + sort + index)") { await model.setTracks(tracks) }
        #expect(model.rows.count == Self.trackCount)
        #expect(loadMS < 6_000)

        let (selectAll, selectAllMS) = await Self.measure("select all → selected rows + summary") { () -> TrackSelectionSummary in
            model.selection = Set(model.rows.map(\.id))
            return TrackSelectionSummary(rows: model.selectedRows(), container: .library, live: .idle)
        }
        #expect(selectAll.count == Self.trackCount)
        #expect(selectAllMS < 1_000)

        let (step, stepMS) = await Self.measure("arrow step → selected rows + summary") { () -> TrackSelectionSummary in
            model.selection = [model.rows[5_000].id]
            return TrackSelectionSummary(rows: model.selectedRows(), container: .library, live: .idle)
        }
        #expect(step.count == 1)
        #expect(stepMS < 50, "an arrow step costs O(selection), not O(rows)")

        let (_, resortMS) = await Self.measure("re-sort in place (title)") {
            await model.setSortOrder(TrackSortOrder(column: .title, ascending: true))
        }
        #expect(model.selection.count == 1, "selection survives the sort")
        #expect(resortMS < 3_000)
    }
}
