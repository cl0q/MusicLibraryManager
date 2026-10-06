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
    /// `1 download is` · `2 downloads and 1 sync are` — built from the counts (W3-SET).
    let runningPhrase: String
    /// The operations that pick up again when the library is opened next, as counted groups
    /// (`2 downloads and 1 sync`); `nil` when none can.
    let continuingPhrase: String?
    let continuingCount: Int
    /// Running work that must not be interrupted: Quit and Switch are refused while it runs.
    let blocker: Blocker?

    struct Blocker: Equatable, Sendable {
        let kind: ActivityKind
        let title: String
    }

    var isEmpty: Bool { operationCount == 0 }

    /// Lines shown before `and ‹n› more`.
    static let maxLines = 5

    /// Kinds that do not continue later: they simply stop (W3-LAUNCH review S4).
    static let nonContinuingKinds: Set<ActivityKind> = [.restore, .backup, .libraryAdoption, .transcodeCacheMove, .pathMigration]

    /// Kinds that replace or move the library's files and must not be cut off: while one runs,
    /// MLM refuses to quit or switch. Treated as past its point of no return as soon as it
    /// runs (the operations don't report that point).
    static let blockingKinds: Set<ActivityKind> = [.restore, .libraryAdoption, .pathMigration]

    /// - Parameter operations: Activity's queued, running and paused operations. Work that
    ///   waits for the library drive isn't running and picks up by itself (UC-JOB-10), so it
    ///   is not listed.
    init(operations: [ActivityOperation], maxLines: Int = RunningWorkSummary.maxLines) {
        let stopping = operations
            .filter { $0.state.isActive }
            .filter { if case .drive = $0.wait { return false } else { return true } }
            .sorted { $0.startedAt < $1.startedAt }
        operationCount = stopping.count
        blocker = stopping.first { $0.state == .running && Self.blockingKinds.contains($0.kind) }
            .map { Blocker(kind: $0.kind, title: $0.title) }

        headline = stopping.isEmpty ? "" : "\(Self.counted(stopping)) will stop:"
        runningPhrase = stopping.isEmpty ? "" : "\(Self.counted(stopping)) \(stopping.count == 1 ? "is" : "are")"
        let continuing = stopping.filter { !Self.nonContinuingKinds.contains($0.kind) }
        continuingCount = continuing.count
        continuingPhrase = continuing.isEmpty ? nil : Self.counted(continuing)

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
    /// - Parameter libraryName: the open library, where work continues; `nil` while no library
    ///   is open — then nothing is promised.
    func message(continuingIn libraryName: String?) -> String? {
        guard !isEmpty else { return nil }
        var text = headline
        for line in lines { text += "\n• " + line }
        if moreCount > 0 { text += "\n• and \(moreCount.formatted(.number)) more" }
        if let libraryName, let continuingPhrase {
            let subject: String
            if continuingCount == operationCount {
                subject = operationCount == 1 ? "It continues" : "They continue"
            } else {
                subject = "\(continuingPhrase) \(continuingCount == 1 ? "continues" : "continue")"
            }
            text += "\n\n\(subject) the next time you open “\(libraryName)”."
        }
        return text
    }

    /// The refusal while a blocker runs (`MLM can’t quit while “‹name›” is being restored.`).
    ///
    /// - Parameters:
    ///   - libraryName: the library the work is about; `MLM`'s own words only when none.
    ///   - switching: `can’t switch libraries` instead of `can’t quit`.
    func refusal(libraryName: String?, switching: Bool = false) -> String? {
        guard let blocker else { return nil }
        let verb = switching ? "MLM can’t switch libraries" : "MLM can’t quit"
        let name = libraryName.map { "“\($0)”" }
        switch blocker.kind {
        case .restore:
            return "\(verb) while \(name ?? "a library") is being restored."
        case .libraryAdoption:
            return "\(verb) while \(name.map { "the library file \($0)" } ?? "a library file") is being set up."
        default:
            return "\(verb) while the files of \(name ?? "the library") are being moved."
        }
    }

    /// `2 downloads and 1 sync`.
    private static func counted(_ operations: [ActivityOperation]) -> String {
        var order: [ActivityNoun] = []
        var counts: [ActivityNoun: Int] = [:]
        for operation in operations {
            let noun = noun(for: operation.kind)
            if counts[noun] == nil { order.append(noun) }
            counts[noun, default: 0] += 1
        }
        return joined(order.map { $0.counted(counts[$0] ?? 0) })
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
        case .albumLookup: ActivityNoun(singular: "album lookup", plural: "album lookups")
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
