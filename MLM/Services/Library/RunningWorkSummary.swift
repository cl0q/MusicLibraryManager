import Foundation

/// What stops when MLM quits or relaunches into another library (A-LIB-SWITCH.N01, DEC-032,
/// PP-SHELL-16): read from Activity at the moment of asking, listed — not asked about
/// (UC-SHEET-13). Pure, so the words are unit-tested.
struct RunningWorkSummary: Equatable, Sendable {
    /// `2 downloads and 1 sync will stop:`; empty when nothing runs.
    let headline: String
    /// One line per operation, oldest first (`Import “Liked on SoundCloud” — 12 of 44`).
    let lines: [String]
    /// Operations beyond the listed lines.
    let moreCount: Int
    let operationCount: Int

    var isEmpty: Bool { operationCount == 0 }

    /// Lines shown before `and ‹n› more`.
    static let maxLines = 5

    /// - Parameter operations: Activity's queued, running and paused operations. Work that
    ///   waits for the library drive isn't running and picks up by itself (UC-JOB-10), so it
    ///   is not listed.
    init(operations: [ActivityOperation], maxLines: Int = RunningWorkSummary.maxLines) {
        let stopping = operations
            .filter { $0.state.isActive }
            .filter { if case .drive = $0.wait { return false } else { return true } }
            .sorted { $0.startedAt < $1.startedAt }
        operationCount = stopping.count

        var order: [ActivityNoun] = []
        var counts: [ActivityNoun: Int] = [:]
        for operation in stopping {
            let noun = Self.noun(for: operation.kind)
            if counts[noun] == nil { order.append(noun) }
            counts[noun, default: 0] += 1
        }
        let parts = order.map { $0.counted(counts[$0] ?? 0) }
        headline = parts.isEmpty ? "" : "\(Self.joined(parts)) will stop:"

        lines = stopping.prefix(maxLines).map { operation in
            if let progress = ActivityPresentation.progressText(operation.progress) {
                return "\(operation.title) — \(progress)"
            }
            return operation.title
        }
        moreCount = max(0, stopping.count - maxLines)
    }

    /// The alert message part about running work; nil when nothing runs.
    ///
    /// - Parameter libraryName: the open library, where the work continues.
    func message(continuingIn libraryName: String) -> String? {
        guard !isEmpty else { return nil }
        var text = headline
        for line in lines { text += "\n• " + line }
        if moreCount > 0 { text += "\n• and \(moreCount.formatted(.number)) more" }
        let verb = operationCount == 1 ? "It continues" : "They continue"
        text += "\n\n\(verb) the next time you open “\(libraryName)”."
        return text
    }

    /// The counted noun per kind (`2 downloads`, `1 sync`, `3 scans`).
    static func noun(for kind: ActivityKind) -> ActivityNoun {
        switch kind {
        case .download, .recommendationDownload, .reelsDownload: ActivityNoun(singular: "download", plural: "downloads")
        case .folderScan: ActivityNoun(singular: "scan", plural: "scans")
        case .analysisQueue, .maintenanceAnalysis, .trackAnalysis: ActivityNoun(singular: "analysis", plural: "analyses")
        case .artwork: ActivityNoun(singular: "artwork search", plural: "artwork searches")
        case .createMLExport: ActivityNoun(singular: "export", plural: "exports")
        case .sync: ActivityNoun(singular: "sync", plural: "syncs")
        case .transcodeCacheMove: ActivityNoun(singular: "cache move", plural: "cache moves")
        case .deviceScan: ActivityNoun(singular: "device scan", plural: "device scans")
        case .backup: ActivityNoun(singular: "backup", plural: "backups")
        case .restore: ActivityNoun(singular: "restore", plural: "restores")
        case .pathMigration: ActivityNoun(singular: "path migration", plural: "path migrations")
        case .libraryAdoption: ActivityNoun(singular: "library file setup", plural: "library file setups")
        case .storageSize: ActivityNoun(singular: "size calculation", plural: "size calculations")
        case .sourceRefresh, .playlistRefresh: ActivityNoun(singular: "refresh", plural: "refreshes")
        case .duplicateScan: ActivityNoun(singular: "duplicate search", plural: "duplicate searches")
        case .fileCheck: ActivityNoun(singular: "file check", plural: "file checks")
        case .tagWrite: ActivityNoun(singular: "tag write", plural: "tag writes")
        case .other: ActivityNoun(singular: "operation", plural: "operations")
        }
    }

    /// `a`, `a and b`, `a, b and c` (the mockups' style, no serial comma).
    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
