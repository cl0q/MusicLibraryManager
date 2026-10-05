import Foundation

/// The persisted details for a failed download.
///
/// Dates use ISO 8601 strings in JSON so the value remains stable when read
/// by another app or a future version with different JSON date strategies.
struct TrackDownloadFailure: Codable, Equatable, Hashable, Sendable {
    let reason: String
    let date: Date
    let attempts: Int

    init(reason: String, date: Date, attempts: Int) {
        self.reason = reason
        self.date = date
        self.attempts = max(attempts, 1)
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case date
        case attempts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)

        if let attempts = try? container.decode(Int.self, forKey: .attempts) {
            self.attempts = max(attempts, 1)
        } else if let attemptsText = try? container.decode(String.self, forKey: .attempts),
                  let attempts = Int(attemptsText) {
            self.attempts = max(attempts, 1)
        } else {
            self.attempts = 1
        }

        if let dateText = try? container.decode(String.self, forKey: .date),
           let date = Self.date(from: dateText) {
            self.date = date
        } else {
            // Accept earlier JSONEncoder defaults, which encoded Date as a number.
            self.date = try container.decode(Date.self, forKey: .date)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(Self.dateFormatter.string(from: date), forKey: .date)
        try container.encode(attempts, forKey: .attempts)
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "Download failure JSON was not UTF-8.")
            )
        }
        return json
    }

    static func decodeJSON(_ json: String) throws -> TrackDownloadFailure {
        try JSONDecoder().decode(TrackDownloadFailure.self, from: Data(json.utf8))
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from text: String) -> Date? {
        dateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// A track's user-visible availability, derived **only** from persisted track fields
/// (UC-TABLE-20, DEC-014, migration `v42_track_availability`). Nothing here touches the disk:
/// whether a local file is present is the persisted `file_missing_since` fact, refreshed by
/// `TrackAvailabilityReconciler` while the library folder is reachable.
///
/// "The library's disk is not connected" is **not** a track state — it is window-level
/// (`LibraryDriveState`); rows of local tracks are dimmed with an empty Status then
/// (`TrackRowPresentation`), never `File missing` (N17).
enum TrackAvailability: Codable, Equatable, Hashable, Sendable {
    case local
    case downloading
    case notDownloaded
    case failed(reason: String, date: Date, attempts: Int)
    case fileMissing

    /// Download states that mean "a download for this track is running or queued now".
    static let activeDownloadStatuses: Set<String> = ["downloading", "queued", "in_progress", "in-progress"]
    /// Legacy status words that mean "the last download failed" (no structured record).
    static let legacyFailedStatuses: Set<String> = ["failed", "error"]

    /// The one derivation of a track's availability from its persisted columns. Pure; the SQL
    /// aggregates in `TrackRepository.availabilityCounts` mirror it case for case.
    ///
    /// - Parameters:
    ///   - organizedPath: `organized_path` — `NULL`/empty = no file (not downloaded).
    ///   - fileMissingSince: `file_missing_since` — set only by a reconciliation that saw the
    ///     library folder reachable and the file absent (or by a use-time miss).
    ///   - downloadStatus: `download_status` (`downloading` while a batch runs).
    ///   - downloadFailure: `download_failure` JSON (`TrackDownloadFailure`).
    static func derive(
        organizedPath: String?,
        fileMissingSince: String?,
        downloadStatus: String?,
        downloadFailure: String?
    ) -> TrackAvailability {
        if let organizedPath, !organizedPath.isEmpty {
            if let fileMissingSince, !fileMissingSince.isEmpty { return .fileMissing }
            return .local
        }
        let status = downloadStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // A retry keeps the prior failure record until it succeeds or fails again, but the
        // running download is the truthful state.
        if activeDownloadStatuses.contains(status) { return .downloading }
        if let downloadFailure, !downloadFailure.isEmpty {
            if let failure = try? TrackDownloadFailure.decodeJSON(downloadFailure) {
                return .failed(reason: failure.reason, date: failure.date, attempts: failure.attempts)
            }
            // Unreadable legacy record: still a failure the user can retry.
            return .failed(reason: "Download failed", date: .distantPast, attempts: 1)
        }
        if legacyFailedStatuses.contains(status) {
            return .failed(reason: "Download failed", date: .distantPast, attempts: 1)
        }
        // nil / "remote" before a download; a path is the source of truth for locality.
        return .notDownloaded
    }

    /// Persisted availability per track id — no disk access (replaces the per-load
    /// `fileExists` mapper `TrackPresentationAvailability`, removed in W2-A).
    static func byTrackID(_ tracks: [Track]) -> [Int64: TrackAvailability] {
        var result: [Int64: TrackAvailability] = [:]
        result.reserveCapacity(tracks.count)
        for track in tracks {
            guard let id = track.id else { continue }
            result[id] = track.availability()
        }
        return result
    }

    /// The track has a stored file path (Local or File missing).
    var hasFile: Bool {
        switch self {
        case .local, .fileMissing: true
        case .downloading, .notDownloaded, .failed: false
        }
    }

    /// A download (or retry) would fetch it.
    var isDownloadable: Bool {
        switch self {
        case .notDownloaded, .failed: true
        case .local, .downloading, .fileMissing: false
        }
    }

    /// Sort rank of the Status column (UC-TABLE-04), ascending in the order of the All Tracks
    /// scope bar (UC-SCOPE-02): Local · (Downloading…) · Not downloaded · Download failed ·
    /// File missing. *(IMP-017, proposed)*
    var statusSortRank: Int {
        switch self {
        case .local: 0
        case .downloading: 1
        case .notDownloaded: 2
        case .failed: 3
        case .fileMissing: 4
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case failure
    }

    private enum State: String, Codable {
        case local
        case downloading
        case notDownloaded = "not_downloaded"
        case failed
        case fileMissing = "file_missing"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .local:
            self = .local
        case .downloading:
            self = .downloading
        case .notDownloaded:
            self = .notDownloaded
        case .fileMissing:
            self = .fileMissing
        case .failed:
            let failure = try container.decode(TrackDownloadFailure.self, forKey: .failure)
            self = .failed(
                reason: failure.reason,
                date: failure.date,
                attempts: failure.attempts
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(State.local, forKey: .state)
        case .downloading:
            try container.encode(State.downloading, forKey: .state)
        case .notDownloaded:
            try container.encode(State.notDownloaded, forKey: .state)
        case let .failed(reason, date, attempts):
            try container.encode(State.failed, forKey: .state)
            try container.encode(
                TrackDownloadFailure(reason: reason, date: date, attempts: attempts),
                forKey: .failure
            )
        case .fileMissing:
            try container.encode(State.fileMissing, forKey: .state)
        }
    }
}
