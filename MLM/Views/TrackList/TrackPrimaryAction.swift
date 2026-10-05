import Foundation

// MARK: - Primary action per row kind (UC-PRIM-01…04, DEC-008)

/// What double-click / Return does on a track row. Never opens Info.
enum TrackPrimaryAction: Equatable, Sendable {
    /// Local: play; the rows after it are the queue context (UC-PRIM-01).
    case play
    /// Not downloaded / Download failed: download (retry); it plays when ready (UC-PRIM-02).
    case download
    /// Already downloading: it plays when ready.
    case awaitDownload
    /// File missing: nothing plays; the status bar offers the fix (UC-PRIM-03).
    case fileMissing
    /// Its disk is not connected: nothing plays (UC-PRIM-04).
    case driveNotConnected(volumeName: String)

    static func resolve(row: TrackRow, live: TrackTableLiveState) -> TrackPrimaryAction {
        if TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live) {
            return .driveNotConnected(volumeName: live.offlineVolumeName ?? "The library disk")
        }
        switch row.availability {
        case .local: return .play
        case .fileMissing: return .fileMissing
        case .downloading: return .awaitDownload
        case .notDownloaded, .failed:
            return live.activeDownloadIDs.contains(row.id) ? .awaitDownload : .download
        }
    }

    // MARK: Status-bar wording (UC-STATUS-05/07, §15.2, §15.4)

    /// `Downloading “‹title›” — it will play when it’s ready`
    static func downloadingMessage(title: String) -> String {
        "Downloading “\(title)” — it will play when it’s ready"
    }

    /// `File missing` — followed by its fix buttons (`Download Again`; `Locate…` arrives with W2-C).
    static let fileMissingMessage = "File missing"

    /// `Can’t play — “Lexxar” is not connected.`
    static func driveNotConnectedMessage(_ volumeName: String) -> String {
        "Can’t play — “\(volumeName)” is not connected."
    }

    /// Help text of file actions disabled while the disk is away (UC-CM-05, UC-COPY-13).
    static func driveNotConnectedHelp(_ volumeName: String) -> String {
        "Can’t play — “\(volumeName)” is not connected"
    }

    /// `Download started — 44 tracks` (UC-STATUS-05).
    static func downloadStartedMessage(count: Int) -> String {
        "Download started — \(StatusBarText.tracks(count))"
    }
}

// MARK: - Play when ready

/// The one pending "play it when the download is done" (UC-PRIM-02). A newer request
/// replaces an older one; `Cancel` clears it. Checked after every finished download batch.
@MainActor
final class PendingTrackPlayback {
    static let shared = PendingTrackPlayback()

    struct Request {
        let trackID: Int64
        let activate: (Track, [Track]) -> Void
    }

    private(set) var request: Request?
    private var observer: NSObjectProtocol?

    func playWhenReady(trackID: Int64, activate: @escaping (Track, [Track]) -> Void) {
        request = Request(trackID: trackID, activate: activate)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .downloadDidComplete, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PendingTrackPlayback.shared.downloadsFinished() }
        }
    }

    func cancel() {
        request = nil
    }

    func downloadsFinished(container: DependencyContainer = .shared) {
        guard let request, let repository = container.trackRepository else { return }
        Task {
            guard let track = try? await repository.fetchTrack(id: request.trackID) else { return }
            guard self.request?.trackID == request.trackID else { return }
            switch track.availability() {
            case .local:
                self.request = nil
                request.activate(track, [track])
            case .downloading:
                break  // still running (another batch) — wait for the next one
            default:
                self.request = nil  // failed: the row says Download failed
            }
        }
    }
}
