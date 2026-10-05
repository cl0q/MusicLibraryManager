import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Locate File… (G-TRK-MISSING fix, UC §12.5, §15.4)

/// The one pending Locate File… request of the window: the player state line, the
/// `File missing` status-bar message, the track context menu and Track ▸ Locate File… all
/// start it here; the main window's player hosts the one system file panel.
@MainActor
@Observable
final class LocateFileRequest {
    static let shared = LocateFileRequest()

    private(set) var track: Track?
    var isPresented = false

    /// Ask for the file of a `File missing` track.
    func begin(_ track: Track) {
        guard track.id != nil else { return }
        self.track = track
        isPresented = true
    }

    func finish() {
        track = nil
        isPresented = false
    }
}

/// What Locate File… does with the chosen file — pure decisions in `LocateFileRule`, the
/// write through `TrackLocateRepository`, undoable through the window's `UndoCenter`.
@MainActor
enum LocateFileAction {
    enum Outcome: Equatable {
        case located(relativePath: String)
        case refused(message: String)
        case failed
    }

    /// Point `track` at `fileURL` if it is inside the library folder. One undo step
    /// (`Locate “‹title›”`): Undo writes the previous path and `File missing` flag back
    /// exactly. Files are never copied or moved.
    @discardableResult
    static func locate(
        _ track: Track,
        at fileURL: URL,
        libraryRoot: String?,
        repository: TrackLocateRepository,
        undo: UndoCenter,
        didChange: @escaping @MainActor () -> Void = Self.postAvailabilityChange
    ) async -> Outcome {
        guard let trackID = track.id else { return .failed }
        switch LocateFileRule.verdict(for: fileURL, libraryRoot: libraryRoot) {
        case .noLibraryFolder:
            return .refused(message: LocateFileRule.noLibraryFolderMessage)
        case .outsideLibraryFolder:
            return .refused(message: LocateFileRule.outsideMessage(fileName: fileURL.lastPathComponent))
        case .inside(let relativePath):
            do {
                _ = try await undo.perform(
                    LocateFileRule.actionName(title: track.title),
                    failure: "Couldn’t locate the file of “\(track.title)”",
                    do: { () async throws -> TrackLocateRepository.FileLocation? in
                        let previous = try await repository.relocate(trackID: trackID, toRelativePath: relativePath)
                        didChange()
                        return previous
                    },
                    undo: { previous in
                        let located = try await repository.restore(previous)
                        didChange()
                        return located
                    },
                    redo: { located in
                        let previous = try await repository.restore(located)
                        didChange()
                        return previous
                    },
                    message: { _ in LocateFileRule.doneMessage(title: track.title) }
                )
                return .located(relativePath: relativePath)
            } catch {
                AppLogger.shared.log("Locate File… failed for track id=\(trackID): \(error.localizedDescription)",
                                     level: .warning, source: "Playback")
                return .failed
            }
        }
    }

    /// Track lists and Info re-read the row in place (no full file check is needed: the new
    /// path was just verified by the panel).
    static func postAvailabilityChange() {
        NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil, userInfo: ["changed": 1])
    }
}

/// Hosts the system file panel of Locate File… (UC-SHEET-24: `.fileImporter` with a message
/// line; audio types only). Attached once, to the main window's player.
struct LocateFilePanel: ViewModifier {
    @Bindable private var request = LocateFileRequest.shared
    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undoCenter: UndoCenter?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $request.isPresented, allowedContentTypes: [.audio]) { result in
                guard let track = request.track else { return }
                request.finish()
                guard case .success(let url) = result else { return }
                choose(url, for: track)
            }
            .fileDialogMessage(LocateFileRule.panelMessage(title: request.track?.title ?? ""))
            .fileDialogConfirmationLabel("Locate")
    }

    private func choose(_ url: URL, for track: Track) {
        guard let repository = TrackLocateRepository.live(container) else { return }
        let undo = undoCenter ?? UndoCenter.main
        let statusBar = self.statusBar
        let config = container.configRepository
        let playback = container.playbackViewModel
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let root = (try? await config?.getLibraryRoot()) ?? nil
            let outcome = await LocateFileAction.locate(track, at: url, libraryRoot: root, repository: repository, undo: undo)
            switch outcome {
            case .located:
                playback?.fileWasLocated(trackID: track.id)
            case .refused(let message):
                statusBar?.post(message, actions: [StatusAction("Locate…") { LocateFileRequest.shared.begin(track) }])
            case .failed:
                break  // the undo center posted `Couldn’t locate … · Try Again`
            }
        }
    }
}

extension View {
    /// The Locate File… panel of the main window (one per window).
    func locateFilePanel() -> some View {
        modifier(LocateFilePanel())
    }
}
