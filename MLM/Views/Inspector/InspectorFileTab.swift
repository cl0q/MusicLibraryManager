import AppKit
import SwiftUI

/// Info ▸ File (P-INSPECTOR-FILE): the availability sentence with its one fix, the tag-write
/// echo, location, file facts, source (`Linked to ‹Source›`), the duplicate hint with a link
/// that focuses the group in Review, and `Diagnostics` on demand (P-INSPECTOR-DEBUG).
struct InspectorFileTab: View {
    let tracks: [Track]

    var body: some View {
        Form {
            if tracks.count == 1, let track = tracks.first {
                InspectorSingleFile(track: track)
            } else {
                InspectorMultipleFiles(tracks: tracks)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - One track

private struct InspectorSingleFile: View {
    let track: Track

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @State private var details = Details()

    /// What the tab reads once per track (and again when something changes).
    struct Details: Equatable {
        var trackID: Int64?
        var fileURL: URL?
        var path: String?
        var size: Int64?
        var sourceName: String?
        var duplicateOf: Track?
        var pending: PendingTagWrite?
    }

    var body: some View {
        let availability = track.availability()
        let offline = InspectorDrive.offlineVolume(container)
        let status = InspectorFileStatus.make(
            track: track,
            availability: availability,
            offlineVolume: offline,
            libraryVolumeName: InspectorDrive.libraryVolumeName(container),
            sourceName: details.sourceName
        )
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label {
                    Text(status.text)
                } icon: {
                    if status.showsProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: status.systemImage)
                            .foregroundStyle(TrackStatusLabel.symbolStyle(status.tint))
                    }
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = status.action {
                    Button(action.title) { perform(action) }
                        .padding(.top, Spacing.xxs)
                }
            }
            .accessibilityElement(children: .contain)
            if let echo = InspectorFileStatus.tagWriteEcho(details.pending, offlineVolumeName: offline?.name) {
                Label(echo, systemImage: details.pending?.blocked == true ? "exclamationmark.triangle" : "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if availability.hasFile {
            Section("Location") {
                Text(details.path ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") {
                        if let url = details.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(!status.isFileReachable || details.fileURL == nil)
                    .help(showInFinderHelp(status, offline: offline))
                    Button("Copy Path") {
                        guard let path = details.path else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                    .disabled(details.path == nil)
                }
            }
        }

        Section("File") {
            LabeledContent("Format", value: availability.hasFile ? Self.nonEmpty(track.format)?.uppercased() ?? "—" : "—")
            LabeledContent("Bitrate") {
                Text(track.bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil } ?? "—").monospacedDigit()
            }
            LabeledContent("Size") {
                Text(details.size.map { $0.formatted(.byteCount(style: .file)) } ?? "—").monospacedDigit()
            }
            LabeledContent("Added") {
                Text(Self.dayText(track.dateAddedLibrary ?? track.dateAdded) ?? "—").monospacedDigit()
            }
            if availability.hasFile, let downloaded = Self.dayText(track.downloadStatus) {
                LabeledContent("Downloaded") { Text(downloaded).monospacedDigit() }
            }
            LabeledContent("Source") {
                if let source = details.sourceName {
                    HStack(spacing: Spacing.xxs) {
                        SourceBrandDot(source: source)
                        Text("Linked to \(source)")
                    }
                } else {
                    Text("Imported from a folder")
                }
            }
        }

        if track.isDuplicate == 1 || track.variantOf != nil {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(Self.duplicateText(details.duplicateOf), systemImage: "square.on.square")
                    Button("Show in Review") {
                        guard let id = track.id else { return }
                        NotificationCenter.default.post(name: .showReview, object: nil, userInfo: ["trackId": id])
                    }
                }
            }
        }

        Section {
            DisclosureGroup("Diagnostics") {
                InspectorDiagnostics(track: track, fileURL: status.isFileReachable ? details.fileURL : nil, offlineName: offline?.name)
            }
        }
        .task(id: track) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .pendingTagWritesDidChange)) { _ in
            Task { await loadPending() }
        }
    }

    private func perform(_ action: InspectorFileStatus.Action) {
        let busy = container.downloadViewModel?.isDownloading == true
        switch action {
        case .download, .retryDownload:
            guard !busy else { statusBar?.post(TrackCommandState.downloadBusyReason); return }
            TrackCommandActions.download([track], container: container)
            statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: 1))
        case .downloadAgain:
            guard !busy else { statusBar?.post(TrackCommandState.downloadBusyReason); return }
            InspectorDownloadAgain.run(track, container: container, statusBar: statusBar)
        }
    }

    private func showInFinderHelp(_ status: InspectorFileStatus, offline: (name: String, path: String)?) -> String {
        if let offline { return "“\(offline.name)” is not connected" }
        if track.availability() == .fileMissing { return "The file is missing" }
        return "Show in Finder"
    }

    private func load() async {
        var next = Details(trackID: track.id)
        if details.trackID == track.id { next.pending = details.pending }
        let availability = track.availability()
        if availability.hasFile, let organized = track.organizedPath {
            let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
            if (organized as NSString).isAbsolutePath {
                next.path = organized
            } else if let root {
                next.path = URL(fileURLWithPath: root).appendingPathComponent(organized).path
            } else {
                next.path = organized
            }
            if availability == .local, InspectorDrive.offlineVolume(container) == nil {
                // One explicit file action for one track (not a per-row probe, UC-TABLE-20).
                next.fileURL = await TrackFileLocator.localURL(for: track, container: container)
                if let url = next.fileURL {
                    next.size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                }
            }
        }
        if let pool = container.databaseManager?.pool, let id = track.id {
            let queries = InspectorQueries(database: pool)
            let stored = (try? await queries.sourceNames(trackID: id)) ?? []
            next.sourceName = stored.first.map(PlaylistEffects.sourceDisplayName) ?? Self.sourceFromPath(track)
            if let reference = track.variantOf {
                next.duplicateOf = try? await queries.track(id: reference)
            }
        }
        details = next
        await loadPending()
    }

    private func loadPending() async {
        guard let pool = container.databaseManager?.pool, let id = track.id else { return }
        details.pending = try? await TrackTagRepository(database: pool).pendingWrite(trackID: id)
    }

    /// A source when nothing is stored in `track_sources`: only a web origin counts.
    private static func sourceFromPath(_ track: Track) -> String? {
        let name = TrackMetadataPresentation.sourceName(for: track)
        return name == "Local import" || name == "Reels" ? nil : name
    }

    /// `Possible duplicate of “‹title›” (‹format›, ‹kbps› kbps).` (§15.4)
    static func duplicateText(_ other: Track?) -> String {
        guard let other else { return "Possible duplicate." }
        var facts: [String] = []
        if let format = nonEmpty(other.format), other.availability().hasFile { facts.append(format.uppercased()) }
        if let kbps = other.bitrate, kbps > 0 { facts.append("\(kbps) kbps") }
        let suffix = facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))"
        return "Possible duplicate of “\(other.title)”\(suffix)."
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// An ISO 8601 stamp as the user's abbreviated date; other stored words (`remote`) → nil.
    static func dayText(_ stamp: String?) -> String? {
        guard let stamp else { return nil }
        var cache: [Substring: String] = [:]
        return TrackRowBuilder.dayText(stamp, cache: &cache)
    }
}

// MARK: - Several tracks (P-INSPECTOR.N10)

private struct InspectorMultipleFiles: View {
    let tracks: [Track]

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    var body: some View {
        let availabilities = tracks.map { $0.availability() }
        let downloadable = tracks.filter { $0.availability().isDownloadable }
        let offline = InspectorDrive.offlineVolume(container)
        Section {
            Text(InspectorFileStatus.summary(availabilities))
                .monospacedDigit()
            if !downloadable.isEmpty {
                Button("Download \(downloadable.count.formatted(.number))") {
                    guard container.downloadViewModel?.isDownloading != true else {
                        statusBar?.post(TrackCommandState.downloadBusyReason)
                        return
                    }
                    TrackCommandActions.download(downloadable, container: container)
                    statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: downloadable.count))
                }
            }
        }
        Section("File") {
            let formats = Array(Set(tracks.filter { $0.availability().hasFile }.compactMap { track -> String? in
                let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
                return format.isEmpty ? nil : format.uppercased()
            })).sorted()
            LabeledContent("Formats", value: formats.isEmpty ? "—" : formats.joined(separator: ", "))
            Button("Show in Finder") { TrackCommandActions.showInFinder(tracks, container: container) }
                .disabled(offline != nil || !availabilities.contains(.local))
                .help(offline.map { "“\($0.name)” is not connected" } ?? "Show in Finder")
        }
    }
}

// MARK: - Download Again (IMP-025)

@MainActor
enum InspectorDownloadAgain {
    /// The table's safe Download Again (`TrackDownloadAgain`, W2-A review S1): re-check the file,
    /// go on only when the check completed and the folder is reachable, never clear the stored
    /// path — only a finished download replaces it.
    static func run(_ track: Track, container: DependencyContainer, statusBar: StatusBarCenter?) {
        guard let id = track.id, let repository = container.trackRepository, let downloads = container.downloadViewModel,
              let monitor = container.availabilityMonitor else { return }
        let volumeName = LibraryDriveState.current(container).volumeName
        Task {
            let prepared = await TrackDownloadAgain.prepare(
                ids: [id],
                repository: repository,
                check: { await monitor.checkNow(.tracks($0)) },
                isFolderReachable: { await monitor.isLibraryFolderReachable() }
            )
            switch prepared {
            case .ready(let tracks):
                statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: tracks.count))
                await downloads.downloadTracks(tracks)
            case .notConnected:
                statusBar?.post(TrackDownloadAgain.notConnectedMessage(volumeName))
            case .nothingMissing:
                NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil)
            case .checkStopped:
                statusBar?.post(TrackDownloadAgain.checkStoppedMessage)
            }
        }
    }
}

// MARK: - Diagnostics (P-INSPECTOR-DEBUG)

/// The Debug tab as a disclosure: nothing runs until `Check File`; the answer first in words,
/// the numbers below, the decoder log behind `Copy Report`.
struct InspectorDiagnostics: View {
    let track: Track
    let fileURL: URL?
    let offlineName: String?

    @State private var result: TrackDiagnosticsService.TrackDiagnostics?
    @State private var isRunning = false
    @State private var toolMissing = false

    var body: some View {
        Group {
            if let offlineName {
                Text("Can’t check the file — “\(offlineName)” is not connected.")
                    .foregroundStyle(.secondary)
            } else if !track.availability().hasFile {
                Text("There is no file to check.")
                    .foregroundStyle(.secondary)
            } else if fileURL == nil {
                Text("Can’t check the file — it isn’t where MLM expects it.")
                    .foregroundStyle(.secondary)
            } else if isRunning {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking the file…").foregroundStyle(.secondary)
                }
            } else if toolMissing {
                InspectorIssueLine(message: "Can’t check the file — ffmpeg not found")
            } else if let result {
                report(result)
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Decodes the whole file to find damage. Takes a few seconds for long mixes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Check File") { run() }
                }
            }
        }
        .task(id: track.id) {
            result = nil
            toolMissing = false
        }
    }

    @ViewBuilder
    private func report(_ result: TrackDiagnosticsService.TrackDiagnostics) -> some View {
        let clean = result.errorCount == 0 && result.brokenFrameCount == 0 && result.decodeExitCode == 0
        Label(clean ? "The file decodes cleanly" : "The file has \(result.errorCount.formatted(.number)) decode \(result.errorCount == 1 ? "error" : "errors")",
              systemImage: clean ? "checkmark.circle" : "exclamationmark.triangle")
        LabeledContent("Container", value: result.containerFormat ?? "—")
        LabeledContent("Codec", value: result.codecName ?? "—")
        LabeledContent("Sample rate") { Text(result.sampleRateHz.map { "\($0.formatted(.number)) Hz" } ?? "—").monospacedDigit() }
        LabeledContent("Channels") { Text(result.channels.map { String($0) } ?? "—").monospacedDigit() }
        LabeledContent("Decode errors") { Text(result.errorCount, format: .number).monospacedDigit() }
        LabeledContent("Broken frames") { Text(result.brokenFrameCount, format: .number).monospacedDigit() }
        HStack {
            Button("Check Again") { run() }
            Button("Copy Report") {
                let lines = result.errorLines + result.warningLines + result.probeErrorLines
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.isEmpty ? "No decode errors." : lines.joined(separator: "\n"), forType: .string)
            }
        }
        Text("ffmpeg · checked \(result.ranAt.formatted(date: .omitted, time: .shortened))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func run() {
        guard let fileURL else { return }
        isRunning = true
        Task {
            let diagnostics = await TrackDiagnosticsService.diagnose(fileURL: fileURL)
            isRunning = false
            result = diagnostics
            toolMissing = diagnostics == nil
        }
    }
}

// MARK: - Source brand dot (UC-COLOR-07)

/// The 6 pt brand dot before a source name — the only place a brand colour appears. Values are
/// the adaptive ones of the retired `mlmBrand*` tokens; other sources get a `.tertiary` dot.
/// (UC-COLOR-07's shared `SourceBrand` type; move to `Views/Shared` when a second view needs it.)
struct SourceBrandDot: View {
    let source: String

    static let size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Self.style(for: source))
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }

    static func style(for source: String) -> AnyShapeStyle {
        switch source {
        case "SoundCloud": AnyShapeStyle(brand(light: (255, 85, 0), dark: (230, 77, 0)))
        case "Spotify": AnyShapeStyle(brand(light: (29, 185, 84), dark: (26, 166, 77)))
        case "YouTube": AnyShapeStyle(brand(light: (255, 0, 0), dark: (230, 0, 0)))
        case "Apple Music": AnyShapeStyle(brand(light: (250, 36, 60), dark: (225, 33, 54)))
        default: AnyShapeStyle(.tertiary)
        }
    }

    private static func brand(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        func color(_ rgb: (Int, Int, Int)) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        }
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}
