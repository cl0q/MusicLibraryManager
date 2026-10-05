import Foundation

/// The availability sentence at the top of Info ▸ File and its one fix (P-INSPECTOR-FILE
/// N01–N06, UC-STATE §15.2/§15.4, DEC-014). Pure, so every state is unit-tested; views never
/// build these strings themselves (UC-STATE-03).
struct InspectorFileStatus: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// `Download` (⌘D) — Not downloaded.
        case download
        /// `Retry Download` (⌘D) — Download failed.
        case retryDownload
        /// `Download Again` — File missing with a source (IMP-025). `Locate…` arrives with W2-C.
        case downloadAgain

        var title: String {
            switch self {
            case .download: "Download"
            case .retryDownload: "Retry Download"
            case .downloadAgain: "Download Again"
            }
        }
    }

    /// The state words (§15.4) or the drive sentence (§15.2).
    let text: String
    let systemImage: String
    let tint: TrackStatusDisplay.SymbolTint
    /// A small spinner instead of the symbol (`Downloading…`).
    let showsProgress: Bool
    /// The second, `.secondary` line: the cause and what is safe.
    let detail: String?
    let action: Action?
    /// The file can be reached now (Show in Finder, Diagnostics, Analyze, waveform).
    let isFileReachable: Bool

    /// - Parameters:
    ///   - offlineVolume: the library's disk while it is not connected (`name`, `/Volumes/…`).
    ///   - libraryVolumeName: the library folder's disk name when connected (`Lexxar`); nil for
    ///     a folder on this Mac.
    ///   - sourceName: glossary name of the track's source (`SoundCloud`), if any.
    static func make(
        track: Track,
        availability: TrackAvailability,
        offlineVolume: (name: String, path: String)?,
        libraryVolumeName: String?,
        sourceName: String?
    ) -> InspectorFileStatus {
        let location = TrackRowBuilder.fileLocation(track.organizedPath)
        if availability.hasFile, let offline = offlineVolume, location.isOnVolume(offline.path) {
            // Never `File missing` for an unplugged drive (DEC-014, N17); no action — the fix
            // is the drive.
            return InspectorFileStatus(
                text: LibraryDriveState.bannerSubject(offline.name),
                systemImage: "externaldrive.badge.xmark",
                tint: .attention,
                showsProgress: false,
                detail: "The file can’t be checked or played until “\(offline.name)” is connected again. You can still edit its tags and playlists.",
                action: nil,
                isFileReachable: false
            )
        }
        switch availability {
        case .local:
            let place = libraryVolumeName.map { "On “\($0)”" } ?? "On this Mac"
            return InspectorFileStatus(text: "\(place), ready to play", systemImage: "checkmark.circle", tint: .none,
                                       showsProgress: false, detail: nil, action: nil, isFileReachable: true)
        case .downloading:
            return InspectorFileStatus(text: TrackStatusDisplay.downloading.text, systemImage: TrackStatusDisplay.downloading.systemImage,
                                       tint: .none, showsProgress: true, detail: "It will be playable in a moment.",
                                       action: nil, isFileReachable: false)
        case .notDownloaded:
            let from = sourceName.map { " from \($0)" } ?? ""
            return InspectorFileStatus(text: TrackStatusDisplay.notDownloaded.text, systemImage: TrackStatusDisplay.notDownloaded.systemImage,
                                       tint: .none, showsProgress: false, detail: "MLM knows this track\(from) but has no file yet.",
                                       action: .download, isFileReachable: false)
        case .failed(let reason, let date, _):
            var detail = DownloadRetryBudget.remainingText(for: track.downloadFailureRecord)
            if date != .distantPast {
                detail += " · last tried \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            // Stored reasons are worded at display time, the same as the table (IMP-029).
            let plain = DownloadFailureReasonText.plain(reason, sourceHint: DownloadFailureReasonText.sourceHint(for: track))
            return InspectorFileStatus(text: "\(TrackStatusDisplay.downloadFailed.text) — \(plain)",
                                       systemImage: TrackStatusDisplay.downloadFailed.systemImage, tint: .attention,
                                       showsProgress: false, detail: detail, action: .retryDownload, isFileReachable: false)
        case .fileMissing:
            let place = libraryVolumeName.map { "on “\($0)”" } ?? "in the library folder"
            return InspectorFileStatus(text: TrackStatusDisplay.fileMissing.text, systemImage: TrackStatusDisplay.fileMissing.systemImage,
                                       tint: .error, showsProgress: false,
                                       detail: "The file isn’t at its location \(place). It may have been moved or deleted outside MLM.",
                                       action: TrackLinks.hasSource(track) ? .downloadAgain : nil, isFileReachable: false)
        }
    }

    /// The tag-write echo for one track (UC-JOB-07/10): nil when its file tags are current.
    static func tagWriteEcho(_ pending: PendingTagWrite?, offlineVolumeName: String?) -> String? {
        guard let pending else { return nil }
        if pending.blocked {
            return "Tag changes couldn’t be written to the file — \(pending.lastError ?? "the details are in the log")"
        }
        if let offlineVolumeName { return "Tag changes waiting for “\(offlineVolumeName)”" }
        if let error = pending.lastError { return "Tag changes waiting — \(error)" }
        return "Tag changes waiting to be written"
    }

    /// Summary line for several tracks: `12 local · 2 not downloaded · 1 file missing`.
    static func summary(_ availabilities: [TrackAvailability]) -> String {
        var local = 0, notDownloaded = 0, failed = 0, missing = 0, downloading = 0
        for availability in availabilities {
            switch availability {
            case .local: local += 1
            case .notDownloaded: notDownloaded += 1
            case .failed: failed += 1
            case .fileMissing: missing += 1
            case .downloading: downloading += 1
            }
        }
        var parts: [String] = []
        if local > 0 { parts.append("\(local.formatted(.number)) local") }
        if downloading > 0 { parts.append("\(downloading.formatted(.number)) downloading") }
        if notDownloaded > 0 { parts.append("\(notDownloaded.formatted(.number)) not downloaded") }
        if failed > 0 { parts.append("\(failed.formatted(.number)) download failed") }
        if missing > 0 { parts.append("\(missing.formatted(.number)) file missing") }
        return parts.joined(separator: " · ")
    }
}
