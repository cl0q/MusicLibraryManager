import Foundation

// MARK: - Player and playback words (UC §15.7, §15.2, UC-STATUS-07, DEC-045, PP-MAIN-15)

/// Every sentence playback shows, in one place (UC-STATE-03: views never build state strings
/// ad hoc). The player's title area uses the §15.7 sentences without a final period; the
/// status bar uses the UC-STATUS-05/07 shapes. Raw error text never appears here — it goes to
/// the log only (UC-COPY-11).
enum PlaybackWords {
    // MARK: Player title area (§15.7)

    static let notPlaying = "Not playing"
    static let previewTag = "Preview"
    static let previewHint = "Space to stop · Return to play"
    /// Online results later: `Preview · from YouTube`.
    static func previewTag(fromSource source: String?) -> String {
        guard let source, !source.isEmpty else { return previewTag }
        return "\(previewTag) · from \(source)"
    }

    /// Why the player can't play the shown track.
    enum CantPlay: Equatable, Sendable {
        case notDownloaded
        case fileMissing
        case driveNotConnected(volumeName: String?)
        case unreadable

        init?(_ playability: PlaybackPlayability, volumeName: String?) {
            switch playability {
            case .playable: return nil
            case .notDownloaded: self = .notDownloaded
            case .fileMissing: self = .fileMissing
            case .driveNotConnected: self = .driveNotConnected(volumeName: volumeName)
            case .unreadable: self = .unreadable
            }
        }

        /// The sentence in the player (no period, §15.7).
        var playerSentence: String {
            switch self {
            case .notDownloaded: "Can’t play — not downloaded"
            case .fileMissing: "Can’t play — file missing"
            case .driveNotConnected(let name): "Can’t play — \(PlaybackWords.diskName(name)) is not connected"
            // Not a §15.7 sentence (IMP-W2C-05): the file exists, macOS can't decode it.
            case .unreadable: "Can’t play — the file can’t be read"
            }
        }

        /// The one fix offered with it (§15.7 "Fix" column); `nil` = none.
        var fixTitle: String? {
            switch self {
            case .notDownloaded: "Download"
            case .fileMissing: "Locate…"
            case .driveNotConnected, .unreadable: nil
            }
        }
    }

    /// `“Lexxar”`, or `The library disk` when the name isn't known.
    static func diskName(_ volumeName: String?) -> String {
        guard let volumeName, !volumeName.isEmpty else { return "the library disk" }
        return "“\(volumeName)”"
    }

    // MARK: Preview refusals (UC-STATUS-07, verbatim)

    enum PreviewRefusal: Equatable, Sendable {
        case notSingle
        case notDownloaded
        case fileMissing
        case driveNotConnected(volumeName: String?)
        case unreadable

        init?(_ playability: PlaybackPlayability, volumeName: String?) {
            switch playability {
            case .playable: return nil
            case .notDownloaded: self = .notDownloaded
            case .fileMissing: self = .fileMissing
            case .driveNotConnected: self = .driveNotConnected(volumeName: volumeName)
            case .unreadable: self = .unreadable
            }
        }

        var message: String {
            switch self {
            case .notSingle: "Space previews one track. Select a single track."
            case .notDownloaded: "Can’t preview — not downloaded. Press ⌘D to download."
            case .fileMissing: "Can’t preview — file missing."
            case .driveNotConnected(let name): "Can’t preview — \(PlaybackWords.diskName(name)) is not connected."
            case .unreadable: "Can’t preview — the file can’t be read."
            }
        }
    }

    // MARK: Status bar

    /// `Can’t play — “Lexxar” is not connected.` (UC-STATUS-07, UC-PRIM-04)
    static func cantPlayDriveMessage(_ volumeName: String?) -> String {
        "Can’t play — \(diskName(volumeName)) is not connected."
    }

    /// The note after the queue passed over tracks that can't play (DEC-045, UC-STATUS-05):
    /// `Skipped 2 tracks that aren’t downloaded · Download`. One note per skip run.
    struct SkipNote: Equatable, Sendable {
        let text: String
        /// The one action: `Download` (the skipped not-downloaded tracks) or `Locate…` (one
        /// missing file); `nil` = none.
        let action: Action?

        enum Action: Equatable, Sendable {
            case download(trackIDs: [Int64])
            case locate(trackID: Int64)
        }
    }

    static func skipNote(_ skipped: [SkippedTrack], volumeName: String?) -> SkipNote? {
        guard !skipped.isEmpty else { return nil }
        let count = skipped.count
        let reasons = Set(skipped.map(\.reason))
        let downloadIDs = skipped.filter { $0.reason == .notDownloaded }.compactMap(\.track.id)
        if reasons == [.notDownloaded] {
            let text = count == 1
                ? "Skipped 1 track that isn’t downloaded"
                : "Skipped \(count.formatted(.number)) tracks that aren’t downloaded"
            return SkipNote(text: text, action: .download(trackIDs: downloadIDs))
        }
        if reasons == [.fileMissing] {
            if count == 1, let track = skipped.first?.track {
                return SkipNote(text: "Skipped “\(track.title)” — file missing",
                                action: track.id.map { .locate(trackID: $0) })
            }
            return SkipNote(text: "Skipped \(count.formatted(.number)) tracks — files missing", action: nil)
        }
        if reasons == [.driveNotConnected] {
            return SkipNote(text: "Skipped \(StatusBarText.tracks(count)) — \(diskName(volumeName)) is not connected",
                            action: nil)
        }
        if reasons == [.unreadable] {
            if count == 1, let track = skipped.first?.track {
                return SkipNote(text: "Skipped “\(track.title)” — the file can’t be read", action: nil)
            }
            return SkipNote(text: "Skipped \(count.formatted(.number)) tracks whose files can’t be read", action: nil)
        }
        return SkipNote(text: "Skipped \(StatusBarText.tracks(count)) that can’t play",
                        action: downloadIDs.isEmpty ? nil : .download(trackIDs: downloadIDs))
    }

    /// A track the user asked for couldn't be opened (UC-COPY-11 shape: what · cause; the one
    /// action is added by the caller). Raw error text goes to the log only.
    static func couldntPlay(_ title: String, _ cause: CantPlay) -> String {
        switch cause {
        case .notDownloaded: "Couldn’t play “\(title)” — it isn’t downloaded"
        case .fileMissing: "Couldn’t play “\(title)” — its file is missing"
        case .driveNotConnected(let name): "Couldn’t play “\(title)” — \(diskName(name)) is not connected"
        case .unreadable: "Couldn’t play “\(title)” — the file can’t be read"
        }
    }

    /// Two files in a row were missing in one queue advance: the disk is probably failing; the
    /// file check judges them instead of flagging them here (UC-COPY-11 shape: what — why).
    static func filesUnreadable(_ volumeName: String?) -> String {
        "Playback stopped — files on \(diskName(volumeName)) can’t be read"
    }

    /// The audio output wouldn't start (engine failure).
    static func outputFailed(_ title: String) -> String {
        "Couldn’t play “\(title)” — the audio output didn’t start"
    }

    /// `“Lexxar” was disconnected — playback paused at 1:12.` (§15.2)
    static func disconnectedPaused(_ volumeName: String?, at time: String) -> String {
        "\(diskName(volumeName).capitalizedFirst) was disconnected — playback paused at \(time)."
    }

    /// `m:ss` (`h:mm:ss` from one hour), UC-COPY-10.
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
