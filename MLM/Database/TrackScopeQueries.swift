import Foundation
import GRDB

// MARK: - Scoped aggregates (W2-B, UC-TABLE-21, UC-STATUS-02, UC-SCOPE-01)

/// Everything a track view with the availability scope bar shows *about* its rows, from one
/// SQL aggregate over persisted columns: the live count of every scope for the current search,
/// the total duration of every scope (the status bar), and the size of the whole library
/// (window subtitle, sidebar footer). Never computed from loaded rows (UC-TABLE-21).
///
/// The scope predicates are `TrackAvailabilitySQL`'s — the same `TrackRepository.fetchTracks
/// (scope:search:)` fetches the rows with — so counts, totals and rows always agree. The four
/// scopes after `All` partition the library: every track is in exactly one of `Local · Not
/// downloaded · Download failed · File missing`; downloading tracks count as `Not downloaded`
/// (IMP-021).
struct TrackScopeSummary: Equatable, Sendable {
    /// Counts per scope for the current search (`counts.all` = tracks matching the search).
    var counts = TrackAvailabilityCounts()
    /// Seconds per scope for the current search.
    var durations: [TrackAvailabilityScope: Int] = [:]
    /// Every track in the library, ignoring the search.
    var libraryCount = 0

    /// `‹n› tracks · ‹duration›` of one scope (the status bar's default text).
    func totals(for scope: TrackAvailabilityScope) -> TrackListTotals {
        TrackListTotals(count: counts.count(for: scope), duration: durations[scope] ?? 0)
    }
}

/// Read-only aggregate queries over `tracks` for scoped track views.
///
/// A sibling of `TrackRepository` rather than an extension of it: the repository keeps its
/// database private to its file (owned by W2-A), so an extension in another file can't reach
/// it. Built from the same `DatabaseWriter`; fold into `TrackRepository` when that file is
/// next edited.
struct TrackScopeQueries: Sendable {
    let database: any DatabaseReader

    /// The open library's queries; `nil` before a library is open (and in the snapshot
    /// container, which has no `DatabaseManager`).
    @MainActor
    static func current(_ container: DependencyContainer = .shared) -> TrackScopeQueries? {
        container.databaseManager.map { TrackScopeQueries(database: $0.pool) }
    }

    /// One pass over `tracks`: per-scope counts and durations for `search`, plus the library
    /// size. `search` matches like the table's in-place filter (each whitespace-separated term
    /// against the folded `search_text`, AND-ed).
    func scopeSummary(search: String? = nil) async throws -> TrackScopeSummary {
        let (searchSQL, arguments) = Self.searchPredicate(search)
        let scopes = TrackAvailabilityScope.allCases.filter { $0 != .all }
        var columns = [
            "COUNT(*) AS library_count",
            "COALESCE(SUM(CASE WHEN m THEN 1 ELSE 0 END), 0) AS all_count",
            "COALESCE(SUM(CASE WHEN m THEN COALESCE(duration, 0) ELSE 0 END), 0) AS all_duration",
            "COALESCE(SUM(CASE WHEN m AND \(TrackAvailabilitySQL.downloading) THEN 1 ELSE 0 END), 0) AS downloading_count",
        ]
        for scope in scopes {
            guard let predicate = scope.sqlPredicate else { continue }
            columns.append("COALESCE(SUM(CASE WHEN m AND \(predicate) THEN 1 ELSE 0 END), 0) AS \(scope.rawValue)_count")
            columns.append(
                "COALESCE(SUM(CASE WHEN m AND \(predicate) THEN COALESCE(duration, 0) ELSE 0 END), 0) AS \(scope.rawValue)_duration"
            )
        }
        // `m` = the row matches the search, evaluated once per row in the inner select.
        let sql = """
            SELECT \(columns.joined(separator: ", "))
            FROM (
                SELECT duration, organized_path, file_missing_since, download_status, download_failure,
                       (\(searchSQL)) AS m
                FROM tracks
            )
            """
        return try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return TrackScopeSummary() }
            var summary = TrackScopeSummary(libraryCount: row["library_count"])
            summary.counts = TrackAvailabilityCounts(
                all: row["all_count"],
                local: row["local_count"],
                notDownloaded: row["notDownloaded_count"],
                downloading: row["downloading_count"],
                failed: row["downloadFailed_count"],
                fileMissing: row["fileMissing_count"],
                totalDuration: row["all_duration"]
            )
            summary.durations[.all] = row["all_duration"]
            for scope in scopes {
                summary.durations[scope] = row["\(scope.rawValue)_duration"]
            }
            return summary
        }
    }

    /// `1` without a search, else `search_text LIKE ? AND …` per term, folded like the rows'
    /// fetch (`TrackRepository.fetchTracks(scope:search:)`), so the counts follow the filter
    /// exactly.
    static func searchPredicate(_ search: String?) -> (String, StatementArguments) {
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let terms = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return ("1", StatementArguments()) }
        let values = terms.map { "%\(DatabaseManager.foldedSearchText($0))%" }
        let predicate = terms.map { _ in "search_text LIKE ?" }.joined(separator: " AND ")
        return (predicate, StatementArguments(values))
    }
}
