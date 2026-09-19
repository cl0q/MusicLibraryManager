import Foundation

// MARK: - LogLevelFilter

enum LogLevelFilter: String, CaseIterable, Identifiable, Hashable {
    case all, infoPlus, warnPlus, errors, debugOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:       return "All"
        case .infoPlus:  return "Info+"
        case .warnPlus:  return "Warn+"
        case .errors:    return "Errors"
        case .debugOnly: return "Debug"
        }
    }

    func matches(_ level: AppLogger.Level) -> Bool {
        switch self {
        case .all:
            return true
        case .infoPlus:
            return level != .debug
        case .warnPlus:
            return level == .warning || level == .error
        case .errors:
            return level == .error
        case .debugOnly:
            return level == .debug
        }
    }
}

// MARK: - LogSourceFilter

enum LogSourceFilter: Hashable, Equatable {
    case all
    case none
    case exact(String)

    func matches(_ source: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .none:
            return source == nil
        case .exact(let value):
            guard let source = source else { return false }
            let lhs = value.trimmingCharacters(in: .whitespaces).lowercased()
            let rhs = source.trimmingCharacters(in: .whitespaces).lowercased()
            return lhs == rhs
        }
    }
}

// MARK: - LogQuery

struct LogQuery: Hashable {
    var level: LogLevelFilter
    var source: LogSourceFilter
    var searchText: String

    static let initial = LogQuery(level: .all, source: .all, searchText: "")
}

// MARK: - LogFeedResult

struct LogFeedResult {
    let rows: [AppLogger.LogEntry]
    let total: Int
    let matched: Int
    let countsByFilter: [LogLevelFilter: Int]
    let availableSources: [String]

    var isEmpty: Bool { rows.isEmpty }
    /// Deterministic identity of the filtered result. Equal iff the same entries appear in the same order.
    var signature: [UUID] { rows.map(\.id) }
}

// MARK: - LogFeed

enum LogFeed {

    static func evaluate(entries: [AppLogger.LogEntry], query: LogQuery) -> LogFeedResult {
        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespaces)
        let loweredSearch = trimmedSearch.lowercased()
        let hasSearch = !loweredSearch.isEmpty

        let rows = entries.filter { entry in
            guard query.level.matches(entry.level) else { return false }
            guard query.source.matches(entry.source) else { return false }
            if hasSearch {
                let matchesMessage = entry.message.lowercased().contains(loweredSearch)
                let matchesSource = entry.source?.lowercased().contains(loweredSearch) ?? false
                return matchesMessage || matchesSource
            }
            return true
        }

        return LogFeedResult(
            rows: rows,
            total: entries.count,
            matched: rows.count,
            countsByFilter: countsByFilter(entries: entries),
            availableSources: availableSources(in: entries)
        )
    }

    /// Groups sources case-insensitively. Display casing = most-frequent spelling
    /// in the group; ties broken by first occurrence. This avoids the single
    /// lowercase `"sync"` call site winning the menu label over 21 `"Sync"` sites.
    static func availableSources(in entries: [AppLogger.LogEntry]) -> [String] {
        // key: normalized (trimmed+lowered) source
        // value: (display spelling → count, first-seen index for that spelling)
        var groups: [String: (spellings: [(String, Int, Int)], firstGroupIndex: Int)] = [:]

        for (index, entry) in entries.enumerated() {
            guard let raw = entry.source else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()

            if var group = groups[key] {
                if let spellIdx = group.spellings.firstIndex(where: { $0.0 == raw }) {
                    group.spellings[spellIdx].1 += 1
                } else {
                    group.spellings.append((raw, 1, index))
                }
                groups[key] = group
            } else {
                groups[key] = ([(raw, 1, index)], index)
            }
        }

        var result: [String] = []
        result.reserveCapacity(groups.count)
        for (_, group) in groups {
            let best = group.spellings.max { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.2 > b.2  // higher first-seen index loses
            }
            if let spelling = best?.0 {
                result.append(spelling)
            }
        }

        result.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return result
    }

    /// Grouping key: trim whitespace + lowercase. nil/whitespace-only → nil.
    static func normalizedSource(_ source: String?) -> String? {
        guard let source = source else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    static func countsByFilter(entries: [AppLogger.LogEntry]) -> [LogLevelFilter: Int] {
        var counts: [LogLevelFilter: Int] = [.all: 0, .infoPlus: 0, .warnPlus: 0, .errors: 0, .debugOnly: 0]
        for entry in entries {
            counts[.all]! += 1
            switch entry.level {
            case .info:    counts[.infoPlus]! += 1
            case .warning: counts[.infoPlus]! += 1; counts[.warnPlus]! += 1
            case .error:   counts[.infoPlus]! += 1; counts[.warnPlus]! += 1; counts[.errors]! += 1
            case .debug:   counts[.debugOnly]! += 1
            }
        }
        return counts
    }

    static func shouldRequery(
        previousQuery: LogQuery?,
        previousEntryCount: Int,
        newQuery: LogQuery,
        newEntryCount: Int
    ) -> Bool {
        guard let previousQuery = previousQuery else { return true }
        if previousQuery != newQuery { return true }
        if previousEntryCount != newEntryCount { return true }
        return false
    }
}
