import Foundation

/// Which of an operation's failed tracks still fail now. Implemented by
/// `ActivityOperationRepository` with the `Download failed` scope's own predicate, so the
/// toolbar's `‹n› failed`, the playlist header and the scope count agree by construction.
protocol ActivityFailureSource: Sendable {
    func failingTrackIDs(in trackIDs: [Int64]) async throws -> Set<Int64>
}

/// Failures grouped by cause with their fix (UC-JOB-11, P-ACTIVITY-OPS.E03): hundreds of
/// failed downloads become a few causes, each with the one action that helps.
enum ActivityFailureGrouping {
    /// One failed download as the batch reported it.
    struct DownloadFailure: Equatable, Sendable {
        let trackID: Int64
        /// The stored / reported reason (any wording — mapped here).
        let reason: String
        let sourceHint: String?

        init(trackID: Int64, reason: String, sourceHint: String? = nil) {
            self.trackID = trackID
            self.reason = reason
            self.sourceHint = sourceHint
        }
    }

    /// Groups download failures by their plain cause (`DownloadFailureReasonText`, IMP-029 —
    /// never the raw text), largest group first, each with its fix.
    static func groupDownloads(_ failures: [DownloadFailure]) -> [ActivityFailureGroup] {
        var order: [String] = []
        var buckets: [String: (category: DownloadFailureReasonText.Category, ids: [Int64])] = [:]
        for failure in failures {
            let category = DownloadFailureReasonText.classify(failure.reason).0
            let cause = DownloadFailureReasonText.plain(failure.reason, sourceHint: failure.sourceHint)
            if buckets[cause] == nil {
                order.append(cause)
                buckets[cause] = (category, [])
            }
            buckets[cause]?.ids.append(failure.trackID)
        }
        return order.compactMap { cause -> ActivityFailureGroup? in
            guard let bucket = buckets[cause] else { return nil }
            let (fix, retryable, note) = fixFor(bucket.category)
            return ActivityFailureGroup(cause: cause, count: bucket.ids.count, fix: fix,
                                        trackIDs: bucket.ids, isRetryable: retryable, note: note)
        }
        .sorted { $0.count > $1.count }
    }

    /// The fix of a download-failure category.
    static func fixFor(_ category: DownloadFailureReasonText.Category) -> (ActivityFix?, Bool, String?) {
        switch category {
        case .signInExpired:
            return (.reconnect(source: nil), true, nil)
        case .toolMissing, .toolOutdated:
            return (.openSettings(SettingsTab.sources.rawValue), true, nil)
        case .captcha:
            return (.openSettings(SettingsTab.sources.rawValue), true, nil)
        case .libraryFolderUnavailable:
            return (.waitForDrive, true, nil)
        case .drmProtected, .regionBlocked, .unavailable, .downloadsDisabled, .noSourceLink:
            return (.showTracks, false, "Retrying won’t help. Try another source from the track’s menu, or dismiss.")
        case .rateLimited, .timedOut, .offline, .serverError, .noMatch, .noFile, .videoUnavailable,
             .formatUnavailable, .damagedFile, .couldNotSave, .anotherDownloadRunning, .cancelled, .unknown:
            return (.retry, true, nil)
        }
    }

    /// `9 downloads failed — sign-in expired (SoundCloud)` (P-ACTIVITY-OPS.E11).
    static func headline(for group: ActivityFailureGroup, noun: ActivityNoun = ActivityNoun(singular: "download", plural: "downloads")) -> String {
        let cause = group.cause.prefix(1).lowercased() + group.cause.dropFirst()
        // Proper names keep their capital (`yt-dlp not found`, `“Lexxar” not connected`).
        let keepCase = group.cause.hasPrefix("“") || DownloadFailureReasonText.sourceNames.contains { group.cause.hasPrefix($0) }
            || group.cause.hasPrefix("yt-dlp") || group.cause.hasPrefix("scdl")
        return "\(noun.counted(group.count)) failed — \(keepCase ? group.cause : String(cause))"
    }
}
