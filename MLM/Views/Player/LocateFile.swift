import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Locate File… (G-TRK-MISSING fix, UC §12.5, §15.4)

/// The one pending Locate File… request of the window: the player state line, the
/// `File missing` status-bar message, the track context menu and Track ▸ Locate File… all
/// start it here; the main window hosts the one system file panel (`PlaybackWindowSupport`).
@MainActor
@Observable
final class LocateFileRequest {
    static let shared = LocateFileRequest()

    private(set) var track: Track?
    var isPresented = false

    init() {}

    /// Ask for the file of a `File missing` / `Download failed` track.
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

/// What Locate File… does with the chosen file: decide (`prepare`, nothing written), maybe ask,
/// then write (`apply`) as one undo step. Files are never copied or moved.
@MainActor
enum LocateFileAction {
    /// A checked choice, ready to write.
    struct Plan: Equatable {
        let track: Track
        let fileName: String
        let relativePath: String
        let absolutePath: String
        let facts: TrackLocateRepository.FileFacts
        /// Ask before writing (length or format differ).
        let mismatch: LocateFileRule.Mismatch?
    }

    enum Prepared: Equatable {
        case ready(Plan)
        case refused(message: String)
    }

    enum Outcome: Equatable {
        case located(relativePath: String)
        case refused(message: String)
        case failed
    }

    /// Reads the chosen file (off the main actor): its format, length and bitrate.
    static func readFacts(_ url: URL) async -> TrackLocateRepository.FileFacts? {
        await Task.detached(priority: .userInitiated) {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let rate = file.processingFormat.sampleRate
            let seconds = rate > 0 ? Double(file.length) / rate : 0
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let bitrate = seconds > 0 && size > 0 ? Int((Double(size) * 8 / seconds / 1000).rounded()) : nil
            return TrackLocateRepository.FileFacts(format: url.pathExtension.lowercased(),
                                                   bitrate: bitrate,
                                                   duration: seconds > 0 ? Int(seconds.rounded()) : nil)
        }.value
    }

    /// Check the choice: inside the library folder (by file-system identity, not by spelling),
    /// a readable audio file; tell whether its length or format differ from the track's.
    static func prepare(
        _ track: Track,
        at fileURL: URL,
        libraryRoot: String?,
        identity: LocateFileRule.Identity = LocateFileRule.fileSystemIdentity,
        facts: (URL) async -> TrackLocateRepository.FileFacts? = { await readFacts($0) }
    ) async -> Prepared {
        let fileName = fileURL.lastPathComponent
        switch LocateFileRule.verdict(for: fileURL, libraryRoot: libraryRoot, identity: identity) {
        case .noLibraryFolder:
            return .refused(message: LocateFileRule.noLibraryFolderMessage)
        case .outsideLibraryFolder:
            return .refused(message: LocateFileRule.outsideMessage(fileName: fileName))
        case .inside(let relativePath):
            guard let read = await facts(fileURL) else {
                return .refused(message: LocateFileRule.unreadableMessage(fileName: fileName))
            }
            let absolute = URL(fileURLWithPath: libraryRoot ?? "").appendingPathComponent(relativePath).path
            let mismatch = LocateFileRule.mismatch(trackTitle: track.title, trackFormat: track.format,
                                                   trackDuration: track.duration, fileName: fileName, facts: read)
            return .ready(Plan(track: track, fileName: fileName, relativePath: relativePath, absolutePath: absolute,
                               facts: read, mismatch: mismatch))
        }
    }

    /// Write the plan as one undo step (`Locate “‹title›”`): Undo writes every changed column back
    /// exactly. A file another track already uses is refused inside the same transaction.
    @discardableResult
    static func apply(
        _ plan: Plan,
        repository: TrackLocateRepository,
        undo: UndoCenter,
        didChange: @escaping @MainActor () -> Void = Self.postAvailabilityChange
    ) async -> Outcome {
        guard let trackID = plan.track.id else { return .failed }
        do {
            _ = try await undo.perform(
                LocateFileRule.actionName(title: plan.track.title),
                failure: nil,
                do: { () async throws -> TrackLocateRepository.FileLocation? in
                    let previous = try await repository.relocate(trackID: trackID, toRelativePath: plan.relativePath,
                                                                 absolutePath: plan.absolutePath, facts: plan.facts)
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
                message: { _ in LocateFileRule.doneMessage(title: plan.track.title) }
            )
            return .located(relativePath: plan.relativePath)
        } catch TrackLocateRepository.LocateError.alreadyUsed(let other) {
            return .refused(message: LocateFileRule.alreadyUsedMessage(fileName: plan.fileName, otherTitle: other))
        } catch {
            AppLogger.shared.log("Locate File… failed for track id=\(trackID): \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
            return .refused(message: "Couldn’t locate the file of “\(plan.track.title)” — the library file didn’t answer")
        }
    }

    /// Track lists and Info re-read the row in place (no full file check is needed: the new
    /// path was just verified by the panel).
    static func postAvailabilityChange() {
        NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil, userInfo: ["changed": 1])
    }
}

/// Hosts the system file panel of Locate File… (UC-SHEET-24: `.fileImporter` with a message
/// line; audio types only) and the question when the file's length or format differ.
struct LocateFilePanel: ViewModifier {
    @Bindable private var request = LocateFileRequest.shared
    @State private var pending: LocateFileAction.Plan?
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
            .alert(pending?.mismatch?.title ?? "", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ), presenting: pending) { plan in
                Button("Use This File") { apply(plan) }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { plan in
                Text(plan.mismatch?.message ?? "")
            }
    }

    private func choose(_ url: URL, for track: Track) {
        let statusBar = self.statusBar
        let config = container.configRepository
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let root = (try? await config?.getLibraryRoot()) ?? nil
            switch await LocateFileAction.prepare(track, at: url, libraryRoot: root) {
            case .refused(let message):
                statusBar?.post(message, actions: [StatusAction("Locate…") { LocateFileRequest.shared.begin(track) }])
            case .ready(let plan):
                if plan.mismatch != nil {
                    pending = plan
                } else {
                    apply(plan)
                }
            }
        }
    }

    private func apply(_ plan: LocateFileAction.Plan) {
        guard let repository = TrackLocateRepository.live(container) else { return }
        let undo = undoCenter ?? UndoCenter.main
        let statusBar = self.statusBar
        let playback = container.playbackViewModel
        Task {
            switch await LocateFileAction.apply(plan, repository: repository, undo: undo) {
            case .located:
                playback?.fileWasLocated(trackID: plan.track.id)
            case .refused(let message):
                statusBar?.post(message, actions: [StatusAction("Locate…") { LocateFileRequest.shared.begin(plan.track) }])
            case .failed:
                break
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
