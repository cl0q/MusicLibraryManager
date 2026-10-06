import Foundation

// MARK: - Seams and small shared pieces of Reels

extension Notification.Name {
    /// A reel was added, deleted or changed state: Discover recounts what waits.
    static let reelsDidChange = Notification.Name("MLMReelsDidChange")
}

/// What the model needs from the file system: whether the video is there, and the Trash.
protocol ReelFileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    /// Moves the file to the Trash; throws with the reason when it can't.
    func trash(_ url: URL) throws
}

struct LiveReelFiles: ReelFileManaging {
    func fileExists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Where a result's download stands, in the words of the row (V-REELS.E21).
enum ReelResultDownload: Equatable, Sendable {
    case queued
    case downloading
    case inLibrary
    case failed(String)

    var isFinal: Bool {
        switch self {
        case .inLibrary, .failed: true
        case .queued, .downloading: false
        }
    }

    /// `Queued` · `Downloading…` · `In library` · `Download failed — ‹reason›`.
    var word: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading…"
        case .inLibrary: "In library"
        case .failed(let reason): reason.isEmpty ? "Download failed" : "Download failed — \(reason)"
        }
    }
}

/// What handing a result to the download pipeline did.
enum ReelDownloadStart: Equatable, Sendable {
    /// The track row exists (without an album) and its download is queued.
    case started(trackID: Int64)
    /// The result already is a library track.
    case alreadyInLibrary(trackID: Int64)
    /// Nothing was written; the cause in plain words.
    case failed(String)
}

/// Turns a result into a library track through the existing download pipeline.
@MainActor
protocol ReelResultDownloading {
    func start(_ result: ReelSearchResult) async -> ReelDownloadStart
    func progress(of trackID: Int64) async -> ReelResultDownload
}

/// The reel the user had selected, kept while the app runs (V-DISC.E02) — the Reels view is
/// rebuilt when the scope changes, the selection is not lost.
@MainActor
final class ReelsSelectionMemory {
    static let shared = ReelsSelectionMemory()
    var reelID: String?
}

/// Where a drop on the Reels view goes: the live model installs itself here, `DropPerformer`
/// reaches it without knowing the view.
@MainActor
final class ReelsDropRouter {
    static let shared = ReelsDropRouter()
    weak var model: ReelsModel?

    func addFiles(_ urls: [URL]) { model?.addDropped(urls) }
    func fetchLink(_ url: URL) { model?.addDroppedLink(url) }
}
