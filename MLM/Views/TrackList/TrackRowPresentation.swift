import SwiftUI

// MARK: - Live state shared by every row

/// The window-level facts rows depend on, published once by the table (not read per cell
/// from the services): what plays, which downloads run, whether the library's disk is away.
struct TrackTableLiveState: Equatable, Sendable {
    var nowPlayingID: Int64?
    var isPlaying = false
    /// Tracks queued or downloading in the running batch (in-memory download state).
    var activeDownloadIDs: Set<Int64> = []
    /// `/Volumes/<name>` of the library's disk while it is not connected; `nil` = connected
    /// (or a folder on this Mac).
    var offlineVolumePath: String?
    /// `Lexxar` while not connected.
    var offlineVolumeName: String?

    static let idle = TrackTableLiveState()

    /// Only the drive part, read now (for commands outside a table).
    @MainActor
    static func drive(_ container: DependencyContainer) -> TrackTableLiveState {
        let drive = LibraryDriveState.current(container)
        guard drive.isOffline else { return .idle }
        return TrackTableLiveState(offlineVolumePath: container.mountObserver?.libraryVolumePath,
                                   offlineVolumeName: drive.volumeName)
    }

    /// Help of Play / Shuffle disabled because the library's disk is away (§15.2, §15.5).
    var cantPlayReason: String? {
        offlineVolumeName.map(TrackPrimaryAction.driveNotConnectedHelp)
    }
}

extension EnvironmentValues {
    @Entry var trackTableLive: TrackTableLiveState = .idle
}

// MARK: - Status column (UC-TABLE-12, §15.4)

/// What a row's Status cell shows — the exact words of §15.4; `nil` = empty (fine).
struct TrackStatusDisplay: Equatable, Sendable {
    enum SymbolTint: Equatable, Sendable {
        /// `.secondary` like the text.
        case none
        /// "Needs action" (Download failed): system orange, symbol only (UC-COLOR-05).
        case attention
        /// File missing: system red, symbol only.
        case error
    }

    let text: String
    let systemImage: String
    let tint: SymbolTint
    /// A small spinner instead of the symbol (`Downloading…`).
    let showsProgress: Bool

    static let downloading = TrackStatusDisplay(text: "Downloading…", systemImage: "arrow.down.circle", tint: .none, showsProgress: true)
    static let notDownloaded = TrackStatusDisplay(text: "Not downloaded", systemImage: "icloud", tint: .none, showsProgress: false)
    static let downloadFailed = TrackStatusDisplay(text: "Download failed", systemImage: "exclamationmark.arrow.circlepath", tint: .attention, showsProgress: false)
    static let fileMissing = TrackStatusDisplay(text: "File missing", systemImage: "doc.questionmark", tint: .error, showsProgress: false)
    static let notInLibrary = TrackStatusDisplay(text: "Not in library", systemImage: "doc.badge.plus", tint: .none, showsProgress: false)

    /// The Status of a persisted availability (no drive context).
    static func forAvailability(_ availability: TrackAvailability) -> TrackStatusDisplay? {
        switch availability {
        case .local: nil
        case .downloading: .downloading
        case .notDownloaded: .notDownloaded
        case .failed: .downloadFailed
        case .fileMissing: .fileMissing
        }
    }
}

/// Everything about a row that depends on the live state — pure, unit-tested.
struct TrackRowPresentation: Equatable, Sendable {
    let status: TrackStatusDisplay?
    /// UC-TABLE-10: the file isn't reachable now (local / file-missing rows while the
    /// library's disk is not connected). Never for Not downloaded / Download failed (DEC-051).
    let isDimmed: Bool
    /// Not downloaded / failed / downloading rows: neutral `music.note` thumbnail (UC-TABLE-17).
    let showsPlaceholderArtwork: Bool
    let isNowPlaying: Bool

    init(row: TrackRow, live: TrackTableLiveState) {
        self.init(availability: row.availability, fileLocation: row.fileLocation, id: row.id, live: live)
    }

    init(availability: TrackAvailability, fileLocation: TrackFileLocation, id: Int64, live: TrackTableLiveState) {
        let unreachable = Self.isUnreachable(availability: availability, fileLocation: fileLocation, live: live)
        let downloadingNow = live.activeDownloadIDs.contains(id) && !availability.hasFile
        if unreachable {
            // DEC-014: the drive is a window-level state — rows say nothing, never File missing.
            status = nil
        } else if downloadingNow {
            status = .downloading
        } else {
            status = TrackStatusDisplay.forAvailability(availability)
        }
        isDimmed = unreachable
        showsPlaceholderArtwork = !availability.hasFile
        isNowPlaying = live.nowPlayingID == id
    }

    /// The row's file lives on the library's disk and that disk is not connected.
    static func isUnreachable(availability: TrackAvailability, fileLocation: TrackFileLocation, live: TrackTableLiveState) -> Bool {
        guard availability.hasFile, let volume = live.offlineVolumePath else { return false }
        return fileLocation.isOnVolume(volume)
    }
}

// MARK: - Views

/// The Status cell: one `Label`, `.secondary` text, symbol tinted only for failure states.
struct TrackStatusLabel: View {
    let status: TrackStatusDisplay

    var body: some View {
        Label {
            Text(status.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } icon: {
            if status.showsProgress {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.systemImage)
                    .foregroundStyle(Self.symbolStyle(status.tint))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.text)
    }

    static func symbolStyle(_ tint: TrackStatusDisplay.SymbolTint) -> AnyShapeStyle {
        switch tint {
        case .none: AnyShapeStyle(.secondary)
        case .attention: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        }
    }
}

/// Energy / Dance (UC-TABLE-14, DEC-046): the number in monospaced digits and a quiet 5-step
/// bar — filled steps `.secondary`, empty `.quaternary`, no colour ramp; `—` when not analysed.
struct TrackMeter: View {
    let level: Int?

    /// Fixed metrics of the meter glyph (`mlm.css` `.meter i`), not layout spacing.
    private static let stepWidth: CGFloat = 3
    private static let stepHeight: CGFloat = 9
    private static let stepGap: CGFloat = 1

    var body: some View {
        if let level, (1...5).contains(level) {
            HStack(spacing: Spacing.xs) {
                Text(level, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                HStack(spacing: Self.stepGap) {
                    ForEach(1...5, id: \.self) { step in
                        Capsule()
                            .fill(step <= level ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                            .frame(width: Self.stepWidth, height: Self.stepHeight)
                    }
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(level) of 5")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Placeholder thumbnail for rows without a file (UC-TABLE-17): `music.note` on `.quaternary`.
struct TrackPlaceholderArtwork: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }
}
