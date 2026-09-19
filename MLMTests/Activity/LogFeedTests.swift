import Testing
import Foundation
@testable import MLM

/// Pure-model tests for Module 3 — LogFeed.
///
/// These tests reference types that do not exist yet (`LogFeed`, `LogQuery`,
/// `LogLevelFilter`, `LogSourceFilter`, `LogFeedResult`). The test target will
/// not compile until the implementation lands. That is expected and correct.
@Suite("LogFeedTests")
struct LogFeedTests {

    // MARK: - Helpers

    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(
        level: AppLogger.Level = .info,
        source: String? = nil,
        message: String = "msg",
        timestamp: Date? = nil
    ) -> AppLogger.LogEntry {
        AppLogger.LogEntry(
            timestamp: timestamp ?? Self.baseDate,
            level: level,
            message: message,
            source: source
        )
    }

    private func ts(offset: TimeInterval) -> Date {
        Self.baseDate.addingTimeInterval(offset)
    }

    /// Mixed fixture: 3 info, 2 warning, 1 error, 4 debug = 10 entries.
    private var mixedEntries: [AppLogger.LogEntry] {
        [
            makeEntry(level: .info,    source: "Sync",       message: "sync started",   timestamp: ts(offset: 1)),
            makeEntry(level: .info,    source: "Download",   message: "track fetched",  timestamp: ts(offset: 2)),
            makeEntry(level: .info,    source: "Sync",       message: "sync progress",  timestamp: ts(offset: 3)),
            makeEntry(level: .warning, source: "Transcode",  message: "slow encode",    timestamp: ts(offset: 4)),
            makeEntry(level: .warning, source: nil,          message: "orphan warn",    timestamp: ts(offset: 5)),
            makeEntry(level: .error,   source: "Download",   message: "network fail",   timestamp: ts(offset: 6)),
            makeEntry(level: .debug,   source: "perf",       message: "tick 1",         timestamp: ts(offset: 7)),
            makeEntry(level: .debug,   source: "perf",       message: "tick 2",         timestamp: ts(offset: 8)),
            makeEntry(level: .debug,   source: "boot",       message: "init complete",  timestamp: ts(offset: 9)),
            makeEntry(level: .debug,   source: nil,          message: "debug orphan",   timestamp: ts(offset: 10)),
        ]
    }

    // MARK: - Behavior 1: LogLevelFilter.matches

    @Test
    func levelFilter_all_matchesEveryLevel() {
        for level in [AppLogger.Level.info, .warning, .error, .debug] {
            #expect(LogLevelFilter.all.matches(level),
                    ".all must match \(level.rawValue)")
        }
    }

    @Test
    func levelFilter_infoPlus_excludesDebug() {
        #expect(LogLevelFilter.infoPlus.matches(.info),
                ".infoPlus must include .info")
        #expect(LogLevelFilter.infoPlus.matches(.warning),
                ".infoPlus must include .warning")
        #expect(LogLevelFilter.infoPlus.matches(.error),
                ".infoPlus must include .error")
        #expect(!LogLevelFilter.infoPlus.matches(.debug),
                ".infoPlus must exclude .debug")
    }

    @Test
    func levelFilter_warnPlus_matchesWarningAndErrorOnly() {
        #expect(!LogLevelFilter.warnPlus.matches(.info),
                ".warnPlus must exclude .info")
        #expect(LogLevelFilter.warnPlus.matches(.warning),
                ".warnPlus must include .warning")
        #expect(LogLevelFilter.warnPlus.matches(.error),
                ".warnPlus must include .error")
        #expect(!LogLevelFilter.warnPlus.matches(.debug),
                ".warnPlus must exclude .debug")
    }

    @Test
    func levelFilter_errors_matchesErrorOnly() {
        #expect(!LogLevelFilter.errors.matches(.info),
                ".errors must exclude .info")
        #expect(!LogLevelFilter.errors.matches(.warning),
                ".errors must exclude .warning")
        #expect(LogLevelFilter.errors.matches(.error),
                ".errors must include .error")
        #expect(!LogLevelFilter.errors.matches(.debug),
                ".errors must exclude .debug")
    }

    @Test
    func levelFilter_debugOnly_matchesDebugOnly() {
        #expect(!LogLevelFilter.debugOnly.matches(.info),
                ".debugOnly must exclude .info")
        #expect(!LogLevelFilter.debugOnly.matches(.warning),
                ".debugOnly must exclude .warning")
        #expect(!LogLevelFilter.debugOnly.matches(.error),
                ".debugOnly must exclude .error")
        #expect(LogLevelFilter.debugOnly.matches(.debug),
                ".debugOnly must include .debug")
    }

    // MARK: - Behavior 2: countsByFilter

    @Test
    func countsByFilter_hasAllFiveKeys() {
        let result = LogFeed.evaluate(entries: mixedEntries, query: .initial)
        for filter in LogLevelFilter.allCases {
            #expect(result.countsByFilter[filter] != nil,
                    "countsByFilter must contain key for \(filter.rawValue)")
        }
    }

    @Test
    func countsByFilter_exactCounts() {
        let result = LogFeed.evaluate(entries: mixedEntries, query: .initial)
        #expect(result.countsByFilter[.all] == 10,
                ".all count must equal total entries (10)")
        #expect(result.countsByFilter[.infoPlus] == 6,
                ".infoPlus must count info+warning+error (3+2+1 = 6)")
        #expect(result.countsByFilter[.warnPlus] == 3,
                ".warnPlus must count warning+error (2+1 = 3)")
        #expect(result.countsByFilter[.errors] == 1,
                ".errors must count only error entries (1)")
        #expect(result.countsByFilter[.debugOnly] == 4,
                ".debugOnly must count only debug entries (4)")
    }

    @Test
    func countsByFilter_allEqualsEntriesCount() {
        let entries = mixedEntries
        let result = LogFeed.evaluate(entries: entries, query: .initial)
        #expect(result.countsByFilter[.all] == entries.count,
                ".all count must always equal entries.count")
    }

    // MARK: - Behavior 3: case-insensitive source matching

    @Test
    func availableSources_collapsesCaseVariants() {
        let entries: [AppLogger.LogEntry] = [
            makeEntry(source: "Sync",  message: "upper", timestamp: ts(offset: 1)),
            makeEntry(source: "sync",  message: "lower", timestamp: ts(offset: 2)),
            makeEntry(source: "SYNC",  message: "caps",  timestamp: ts(offset: 3)),
        ]
        let sources = LogFeed.availableSources(in: entries)
        #expect(sources.count == 1,
                "availableSources must collapse Sync/sync/SYNC into one entry, got \(sources)")
    }

    @Test
    func sourceFilter_exact_matchesCaseInsensitively() {
        let entry = makeEntry(source: "sync", message: "lowercase source")
        #expect(LogSourceFilter.exact("Sync").matches(entry.source),
                "exact(\"Sync\") must match an entry logged with source \"sync\"")
        #expect(LogSourceFilter.exact("SYNC").matches(entry.source),
                "exact(\"SYNC\") must match an entry logged with source \"sync\"")
    }

    // MARK: - Behavior 4: availableSources dedup + sort + display-casing rule

    @Test
    func availableSources_deduplicatedSorted_mostFrequentCasingWins() {
        // "Sync" appears 2×, "sync" appears 1× → display form must be "Sync".
        // "Download" appears 1× (no case rival) → kept as-is.
        // "boot" appears 1× (no case rival) → kept as-is.
        // nil source must be excluded.
        let entries: [AppLogger.LogEntry] = [
            makeEntry(source: "boot",     timestamp: ts(offset: 1)),
            makeEntry(source: "Download", timestamp: ts(offset: 2)),
            makeEntry(source: "Sync",     timestamp: ts(offset: 3)),
            makeEntry(source: "sync",     timestamp: ts(offset: 4)),
            makeEntry(source: "Sync",     timestamp: ts(offset: 5)),
            makeEntry(source: nil,        timestamp: ts(offset: 6)),
        ]
        let sources = LogFeed.availableSources(in: entries)
        #expect(sources == ["boot", "Download", "Sync"],
                "availableSources must pick the most-frequent casing per group (\"Sync\" 2-1 over \"sync\"), exclude nil, and sort by localizedCaseInsensitiveCompare")
    }

    @Test
    func availableSources_tieBreak_usesFirstOccurrence() {
        // "alpha" and "Alpha" each appear once → first occurrence in input wins.
        let entries: [AppLogger.LogEntry] = [
            makeEntry(source: "Alpha", timestamp: ts(offset: 1)),
            makeEntry(source: "alpha", timestamp: ts(offset: 2)),
            makeEntry(source: "Beta",  timestamp: ts(offset: 3)),
        ]
        let sources = LogFeed.availableSources(in: entries)
        #expect(sources == ["Alpha", "Beta"],
                "tied occurrence counts must resolve to the first occurrence in the input array (\"Alpha\" before \"alpha\")")
    }

    // MARK: - Behavior 5: normalizedSource (grouping key — trim + lowercase)

    @Test
    func normalizedSource_nilReturnsNil() {
        #expect(LogFeed.normalizedSource(nil) == nil,
                "normalizedSource(nil) must be nil")
    }

    @Test
    func normalizedSource_whitespaceOnlyReturnsNil() {
        #expect(LogFeed.normalizedSource("  ") == nil,
                "normalizedSource(\"  \") must be nil — whitespace-only is treated as absent")
    }

    @Test
    func normalizedSource_lowercasesNonEmpty() {
        #expect(LogFeed.normalizedSource("Sync") == "sync",
                "normalizedSource is the grouping key — it must lowercase (\"Sync\" → \"sync\")")
    }

    @Test
    func normalizedSource_trimsAndLowercases() {
        #expect(LogFeed.normalizedSource(" sync ") == "sync",
                "normalizedSource must trim surrounding whitespace AND lowercase (\" sync \" → \"sync\")")
    }

    // MARK: - Behavior 6: LogSourceFilter.none

    @Test
    func sourceFilter_none_matchesOnlyNilSource() {
        #expect(LogSourceFilter.none.matches(nil),
                ".none must match entries with source == nil")
        #expect(!LogSourceFilter.none.matches("Sync"),
                ".none must not match entries with a non-nil source")
        #expect(!LogSourceFilter.none.matches(""),
                ".none must not match empty-string sources")
    }

    // MARK: - Behavior 7: search

    @Test
    func search_caseInsensitive() {
        let entries = [
            makeEntry(source: "Sync", message: "Network error occurred", timestamp: ts(offset: 1)),
            makeEntry(source: "Download", message: "all good", timestamp: ts(offset: 2)),
        ]
        let query = LogQuery(level: .all, source: .all, searchText: "NETWORK")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == 1,
                "search must be case-insensitive")
        #expect(result.rows.first?.message == "Network error occurred",
                "search must match the correct entry")
    }

    @Test
    func search_matchesSourceOrMessage() {
        let entries = [
            makeEntry(source: "Transcode", message: "ok", timestamp: ts(offset: 1)),
            makeEntry(source: "boot", message: "transcode init", timestamp: ts(offset: 2)),
            makeEntry(source: "Sync", message: "nothing here", timestamp: ts(offset: 3)),
        ]
        let query = LogQuery(level: .all, source: .all, searchText: "transcode")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == 2,
                "search must match both source and message fields")
    }

    @Test
    func search_trimsWhitespace() {
        let entries = [
            makeEntry(message: "hello world", timestamp: ts(offset: 1)),
        ]
        let query = LogQuery(level: .all, source: .all, searchText: "  hello  ")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == 1,
                "search must trim surrounding whitespace before matching")
    }

    @Test
    func search_emptyQueryIsNoOp() {
        let entries = mixedEntries
        let query = LogQuery(level: .all, source: .all, searchText: "")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == entries.count,
                "empty search must return all entries unchanged")
    }

    @Test
    func search_whitespaceOnlyQueryIsNoOp() {
        let entries = mixedEntries
        let query = LogQuery(level: .all, source: .all, searchText: "   ")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == entries.count,
                "whitespace-only search must be a no-op")
    }

    // MARK: - Behavior 8: filters compose

    @Test
    func filtersCompose_levelAndSourceAndSearch() {
        let entries: [AppLogger.LogEntry] = [
            makeEntry(level: .error,   source: "Download", message: "timeout",     timestamp: ts(offset: 1)),
            makeEntry(level: .error,   source: "Sync",     message: "timeout",     timestamp: ts(offset: 2)),
            makeEntry(level: .warning, source: "Download", message: "timeout",     timestamp: ts(offset: 3)),
            makeEntry(level: .error,   source: "Download", message: "other error", timestamp: ts(offset: 4)),
        ]
        let query = LogQuery(level: .errors, source: .exact("Download"), searchText: "timeout")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.rows.count == 1,
                "level AND source AND search must all apply simultaneously")
        #expect(result.rows.first?.source == "Download",
                "the surviving row must be from Download source")
        #expect(result.rows.first?.level == .error,
                "the surviving row must be error level")
    }

    // MARK: - Behavior 9: order preserved

    @Test
    func evaluate_preservesInputOrder() {
        let entries: [AppLogger.LogEntry] = [
            makeEntry(message: "first",  timestamp: ts(offset: 3)),
            makeEntry(message: "second", timestamp: ts(offset: 1)),
            makeEntry(message: "third",  timestamp: ts(offset: 2)),
        ]
        let result = LogFeed.evaluate(entries: entries, query: .initial)
        let messages = result.rows.map(\.message)
        #expect(messages == ["first", "second", "third"],
                "evaluate must preserve input order — no sorting")
    }

    // MARK: - Behavior 10: shouldRequery

    @Test
    func shouldRequery_trueWhenPreviousQueryIsNil() {
        let newQuery = LogQuery(level: .all, source: .all, searchText: "")
        #expect(LogFeed.shouldRequery(previousQuery: nil, previousEntryCount: 0,
                                      newQuery: newQuery, newEntryCount: 10),
                "shouldRequery must be true when previousQuery is nil (first evaluation)")
    }

    @Test
    func shouldRequery_trueWhenQueryDiffers() {
        let old = LogQuery(level: .all, source: .all, searchText: "")
        let new = LogQuery(level: .errors, source: .all, searchText: "")
        #expect(LogFeed.shouldRequery(previousQuery: old, previousEntryCount: 10,
                                      newQuery: new, newEntryCount: 10),
                "shouldRequery must be true when the query changes")
    }

    @Test
    func shouldRequery_trueWhenEntryCountDiffers() {
        let query = LogQuery(level: .all, source: .all, searchText: "")
        #expect(LogFeed.shouldRequery(previousQuery: query, previousEntryCount: 10,
                                      newQuery: query, newEntryCount: 15),
                "shouldRequery must be true when entry count changes even if query is identical")
    }

    @Test
    func shouldRequery_falseWhenBothUnchanged() {
        let query = LogQuery(level: .warnPlus, source: .exact("Sync"), searchText: "fail")
        #expect(!LogFeed.shouldRequery(previousQuery: query, previousEntryCount: 42,
                                       newQuery: query, newEntryCount: 42),
                "shouldRequery must be false when both query and entry count are unchanged — this eliminates redundant recomputation")
    }

    // MARK: - Behavior 11: empty input

    @Test
    func evaluate_emptyInput() {
        let result = LogFeed.evaluate(entries: [], query: .initial)
        #expect(result.rows.isEmpty,
                "empty input must produce empty rows")
        #expect(result.isEmpty,
                "empty input must set isEmpty == true")
        #expect(result.total == 0,
                "empty input must have total == 0")
        #expect(result.matched == 0,
                "empty input must have matched == 0")
        #expect(result.availableSources.isEmpty,
                "empty input must have no available sources")
        for filter in LogLevelFilter.allCases {
            #expect(result.countsByFilter[filter] == 0,
                    "empty input must have count 0 for \(filter.rawValue)")
        }
    }

    // MARK: - Behavior 12: performance contract (source scan)

    @Test
    func evaluate_singlePassFilter_sourceScan() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Activity
            .deletingLastPathComponent()  // MLMTests
            .deletingLastPathComponent()  // repo root

        let logFeedURL = repoRoot.appendingPathComponent("MLM/Views/Activity/LogFeed.swift")
        guard let data = try? Data(contentsOf: logFeedURL),
              let source = String(data: data, encoding: .utf8) else {
            Issue.record("LogFeed.swift must exist at MLM/Views/Activity/LogFeed.swift")
            return
        }

        // Extract the body of `evaluate` — count `.filter(` occurrences within it.
        // We look for the function signature and count up to the next top-level `static func` or end of enum.
        guard let evaluateRange = source.range(of: "static func evaluate(") else {
            Issue.record("LogFeed.swift must contain `static func evaluate(`")
            return
        }

        let afterSignature = source[evaluateRange.lowerBound...]
        // Find the end of the function: next `static func` at the same indentation level, or end of file.
        let bodyEnd: String.Index
        if let nextFunc = afterSignature.dropFirst().range(of: "\n    static func ") {
            bodyEnd = nextFunc.lowerBound
        } else {
            bodyEnd = afterSignature.endIndex
        }
        let evaluateBody = String(afterSignature[..<bodyEnd])

        let filterCallCount = evaluateBody.components(separatedBy: ".filter(").count - 1
        #expect(filterCallCount <= 1,
                "evaluate must filter in a single pass — found \(filterCallCount) .filter( calls, expected at most 1")
    }

    // MARK: - LogQuery.initial

    @Test
    func logQuery_initial_hasExpectedDefaults() {
        let q = LogQuery.initial
        #expect(q.level == .all,
                "LogQuery.initial level must be .all")
        #expect(q.source == .all,
                "LogQuery.initial source must be .all")
        #expect(q.searchText.isEmpty,
                "LogQuery.initial searchText must be empty")
    }

    // MARK: - LogFeedResult derived properties

    @Test
    func logFeedResult_totalAndMatched() {
        let entries = mixedEntries
        let query = LogQuery(level: .errors, source: .all, searchText: "")
        let result = LogFeed.evaluate(entries: entries, query: query)
        #expect(result.total == entries.count,
                "total must reflect the input count regardless of filter")
        #expect(result.matched == 1,
                "matched must reflect the filtered row count (1 error)")
    }

    @Test
    func logFeedResult_isEmpty_falseWhenEntriesExist() {
        let result = LogFeed.evaluate(entries: mixedEntries, query: .initial)
        #expect(!result.isEmpty,
                "isEmpty must be false when there are entries")
    }

    // MARK: - LogSourceFilter.all

    @Test
    func sourceFilter_all_matchesEverything() {
        #expect(LogSourceFilter.all.matches(nil),
                ".all must match nil source")
        #expect(LogSourceFilter.all.matches("Sync"),
                ".all must match any non-nil source")
        #expect(LogSourceFilter.all.matches(""),
                ".all must match empty-string source")
    }

    // MARK: - LogLevelFilter labels

    @Test
    func levelFilter_labels() {
        #expect(LogLevelFilter.all.label == "All",
                ".all label must be \"All\"")
        #expect(LogLevelFilter.infoPlus.label == "Info+",
                ".infoPlus label must be \"Info+\"")
        #expect(LogLevelFilter.warnPlus.label == "Warn+",
                ".warnPlus label must be \"Warn+\"")
        #expect(LogLevelFilter.errors.label == "Errors",
                ".errors label must be \"Errors\"")
        #expect(LogLevelFilter.debugOnly.label == "Debug",
                ".debugOnly label must be \"Debug\"")
    }
}
