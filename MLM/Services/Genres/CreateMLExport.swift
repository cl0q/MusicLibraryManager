import Foundation
import Observation

// MARK: - Export Create ML Training Set… (ST-STUDIO-EXPORT, DEC-044)

/// What an export will do, computed before it starts (V-GENRES.N09/N11): which genres are large
/// enough, which are left out, how many tracks are skipped because they aren't downloaded, and
/// about how much space it needs. Pure — built from the tracks that have a genre.
struct CreateMLExportPlan: Equatable, Sendable {
    struct Genre: Equatable, Sendable, Identifiable {
        let key: String
        let name: String
        /// Every track of the genre.
        let trackCount: Int
        var id: String { key }
    }

    /// One file to write: `‹destination›/‹folder›/‹fileBaseName›.‹ext›`.
    struct Item: Equatable, Sendable {
        let track: Track
        let folder: String
        let fileBaseName: String
    }

    let minimumTracks: Int
    let included: [Genre]
    let leftOut: [Genre]
    /// Tracks of the included genres that have a file — what will be written.
    let items: [Item]
    /// Tracks of the included genres without a file (not downloaded, downloading, failed).
    let notDownloaded: Int
    /// AAC 248 kbps over the exported tracks' durations.
    let estimatedBytes: Int64

    var includedTrackCount: Int { included.reduce(0) { $0 + $1.trackCount } }
    var leftOutTrackCount: Int { leftOut.reduce(0) { $0 + $1.trackCount } }

    /// V-GENRES.N11: what is skipped and how much space it needs, said before the start.
    var warning: String {
        guard !included.isEmpty else { return "No genre has that many tracks. Lower the minimum." }
        var text = ""
        if notDownloaded > 0 {
            text = "\(notDownloaded.formatted(.number)) of these tracks \(notDownloaded == 1 ? "is" : "are") not downloaded and will be skipped. "
        }
        return text + "The export needs about \(Self.size(estimatedBytes))."
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let defaultMinimum = 50
    static let bitrateKbps = 248

    static func make(tracks: [Track], minimumTracks: Int) -> CreateMLExportPlan {
        let minimum = max(1, minimumTracks)
        var byKey: [String: [Track]] = [:]
        for track in tracks {
            guard let key = GenreName.key(track.genre), track.id != nil else { continue }
            byKey[key, default: []].append(track)
        }
        var included: [Genre] = []
        var leftOut: [Genre] = []
        var items: [Item] = []
        var notDownloaded = 0
        var seconds = 0
        let ordered = byKey.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        var usedFolders = Set<String>()
        for (key, members) in ordered {
            let name = GenreName.display(spellings: Dictionary(grouping: members, by: { $0.genre ?? "" })
                .map { ($0.key, $0.value.count) })
            let genre = Genre(key: key, name: name, trackCount: members.count)
            guard members.count >= minimum else {
                leftOut.append(genre)
                continue
            }
            included.append(genre)
            let folder = uniqueName(sanitized(name), taken: &usedFolders)
            var usedFiles = Set<String>()
            for track in members.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
                guard track.availability().hasFile else {
                    notDownloaded += 1
                    continue
                }
                let base = sanitized("\(TrackMetadataPresentation.artistDisplay(track.artist) ?? "Unknown Artist") - \(track.title)")
                items.append(Item(track: track, folder: folder, fileBaseName: uniqueName(base, taken: &usedFiles)))
                seconds += max(track.duration ?? 0, 0)
            }
        }
        return CreateMLExportPlan(
            minimumTracks: minimum,
            included: included,
            leftOut: leftOut,
            items: items,
            notDownloaded: notDownloaded,
            estimatedBytes: Int64(seconds) * Int64(bitrateKbps) * 1000 / 8
        )
    }

    /// A file or folder name from a genre / artist / title: no path separators or characters
    /// Finder or Create ML trip over, never empty, never hidden.
    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// `name`, or `name 2`, `name 3` … when taken (case-insensitive, like the Mac's file system).
    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(number)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

// MARK: - Writing one file

/// What happened to one track.
enum CreateMLExportOutcome: Equatable, Sendable {
    case exported
    /// The track has no file (counted before the start).
    case skipped(String)
    case failed(Reason)

    enum Reason: String, Equatable, Sendable {
        case fileMissing = "file missing"
        case notConverted = "could not be converted"
        case notWritten = "could not be written"
    }
}

/// Writes one track into the destination. The live one converts with ffmpeg (or copies the
/// transcode cache's AAC file) — it only **reads** library files and only **writes** below the
/// chosen folder.
struct CreateMLExportFileWriter: Sendable {
    let write: @Sendable (_ item: CreateMLExportPlan.Item, _ destination: URL) async -> CreateMLExportOutcome

    @MainActor
    static func live(_ container: DependencyContainer = .shared) -> CreateMLExportFileWriter {
        let config = container.configRepository.map(UncheckedSendableBox.init)
        return files(libraryRoot: { (try? await config?.value.getLibraryRoot()) ?? nil },
                     cache: container.transcodeCache)
    }

    /// The writer over a library folder and a transcode cache (both only read).
    static func files(
        libraryRoot: @escaping @Sendable () async -> String?,
        cache transcodeCache: TranscodeCache?,
        transcoder: TranscodeService = TranscodeService()
    ) -> CreateMLExportFileWriter {
        let cache = transcodeCache.map(UncheckedSendableBox.init)
        return CreateMLExportFileWriter { item, destination in
            let root = await libraryRoot()
            guard let source = Self.sourceURL(of: item.track, libraryRoot: root) else { return .failed(.fileMissing) }
            let folder = destination.appendingPathComponent(item.folder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return .failed(.notWritten)
            }
            let target = folder.appendingPathComponent(item.fileBaseName + ".m4a")
            // Re-exporting into the same folder replaces the earlier export's file.
            try? FileManager.default.removeItem(at: target)
            // The transcode cache already holds this track as AAC 248 kbps: copy it (a clone on
            // the same volume). The cache is only read.
            if let id = item.track.id, let cached = cache?.value.cachePath(trackId: id, bitrateKbps: CreateMLExportPlan.bitrateKbps),
               ((try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
                do {
                    try FileManager.default.copyItem(at: cached, to: target)
                    return .exported
                } catch {
                    AppLogger.shared.warn("Create ML export: couldn’t copy the cached file of track \(id): \(error.localizedDescription)", source: "CreateML")
                }
            }
            do {
                let result = try await transcoder.transcode(
                    input: source, outputDir: folder, outputName: target.lastPathComponent,
                    bitrateKbps: CreateMLExportPlan.bitrateKbps,
                    sourceFormat: nil, sourceBitrate: nil)
                switch result {
                case .transcoded:
                    return .exported
                case .skipped:
                    // A lossy file below 248 kbps is copied as it is, under its own extension
                    // (the old export gave an MP3 an `.m4a` name).
                    let copy = folder.appendingPathComponent(item.fileBaseName)
                        .appendingPathExtension(source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased())
                    if FileManager.default.fileExists(atPath: copy.path) { try? FileManager.default.removeItem(at: copy) }
                    try FileManager.default.copyItem(at: source, to: copy)
                    return .exported
                case .failed(let reason):
                    AppLogger.shared.warn("Create ML export: “\(item.track.title)” not converted — \(reason)", source: "CreateML")
                    return .failed(.notConverted)
                }
            } catch {
                AppLogger.shared.warn("Create ML export: “\(item.track.title)” failed — \(error.localizedDescription)", source: "CreateML")
                return .failed(.notConverted)
            }
        }
    }

    /// The track's file in the library folder (organised path), else its absolute original path.
    nonisolated static func sourceURL(of track: Track, libraryRoot: String?) -> URL? {
        let manager = FileManager.default
        if let root = libraryRoot, let organized = track.organizedPath, !organized.isEmpty {
            let url = (organized as NSString).isAbsolutePath
                ? URL(fileURLWithPath: organized)
                : URL(fileURLWithPath: root).appendingPathComponent(organized)
            if manager.fileExists(atPath: url.path) { return url }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if manager.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return nil
    }
}

// MARK: - The run (an Activity operation with a real Cancel)

/// The result of an export: `Exported 1,204 tracks, 9 skipped, 2 failed`.
struct CreateMLExportSummary: Equatable, Sendable {
    var exported = 0
    var skipped = 0
    var failedNotConverted = 0
    var failedMissing = 0
    var failedNotWritten = 0
    var wasCancelled = false

    var failed: Int { failedNotConverted + failedMissing + failedNotWritten }

    /// The status-bar sentence (UC-STATUS-05 shape: counts after a comma).
    var sentence: String {
        var parts = ["\(wasCancelled ? "Export cancelled — exported" : "Exported") \(StatusBarText.tracks(exported))"]
        if skipped > 0 { parts.append("\(skipped.formatted(.number)) skipped") }
        if failed > 0 { parts.append("\(failed.formatted(.number)) failed") }
        return parts.joined(separator: ", ")
    }

    var activityResult: ActivityResult {
        var groups: [ActivityFailureGroup] = []
        if failedNotConverted > 0 { groups.append(ActivityFailureGroup(cause: "Couldn’t be converted", count: failedNotConverted, fix: nil, isRetryable: false)) }
        if failedMissing > 0 { groups.append(ActivityFailureGroup(cause: "File missing", count: failedMissing, fix: nil, isRetryable: false)) }
        if failedNotWritten > 0 { groups.append(ActivityFailureGroup(cause: "Couldn’t write into the destination", count: failedNotWritten, fix: nil, isRetryable: false)) }
        return ActivityResult(
            counts: [ActivityCount(.done, exported, "exported"), ActivityCount(.skipped, skipped, "skipped — not downloaded"),
                     ActivityCount(.failed, failed, "failed")],
            failureGroups: groups)
    }
}

/// Runs exports: one at a time, each an Activity operation (`Create ML export · ‹folder›`) with
/// an honest Cancel (`Cancel After This File`: files being converted finish). Outlives the sheet
/// that started it — the sheet closes on `Export n Tracks` (UC-SHEET-07).
@MainActor
@Observable
final class CreateMLExporter {
    static let shared = CreateMLExporter()

    private(set) var isRunning = false
    private(set) var lastSummary: CreateMLExportSummary?
    @ObservationIgnored private var task: Task<CreateMLExportSummary, Never>?

    /// The folder the last export went to (remembered between exports, ST-STUDIO-EXPORT.E06).
    static let destinationKey = "createml.destinationPath"
    static let minimumKey = "createml.minimumTracks"

    /// Start the export of `plan` into `destination`. Returns the summary when it ends.
    @discardableResult
    func run(_ plan: CreateMLExportPlan, into destination: URL, writer: CreateMLExportFileWriter,
             workers: Int, activity: ActivityCenter = .shared,
             onEnd: (@MainActor (CreateMLExportSummary) -> Void)? = nil) -> Task<CreateMLExportSummary, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        let items = plan.items
        let total = items.count
        let job = activity.begin(
            .createMLExport, title: "Create ML export · \(destination.lastPathComponent)",
            subject: .genres, progress: ActivityProgress(total: total), itemNoun: .track,
            controls: ActivityControls(cancelStyle: .afterThisFile, cancel: { [weak self] in Task { @MainActor in self?.cancel() } })
        )
        var summary = CreateMLExportSummary()
        summary.skipped = plan.notDownloaded
        let workerCount = max(1, workers)
        let task = Task { [summary] () -> CreateMLExportSummary in
            var summary = summary
            var completed = 0
            await withTaskGroup(of: (CreateMLExportOutcome?, String).self) { group in
                var iterator = items.makeIterator()
                func addNext() -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask {
                        if Task.isCancelled { return (nil, item.folder) }
                        return (await writer.write(item, destination), item.folder)
                    }
                    return true
                }
                for _ in 0..<workerCount where !addNext() { break }
                while let (outcome, folder) = await group.next() {
                    if let outcome {
                        completed += 1
                        switch outcome {
                        case .exported: summary.exported += 1
                        case .skipped: summary.skipped += 1
                        case .failed(.fileMissing): summary.failedMissing += 1
                        case .failed(.notConverted): summary.failedNotConverted += 1
                        case .failed(.notWritten): summary.failedNotWritten += 1
                        }
                        job.update(completed: completed, total: total, currentItem: folder)
                    }
                    if !Task.isCancelled { _ = addNext() }
                }
            }
            summary.wasCancelled = Task.isCancelled && completed < total
            return summary
        }
        self.task = task
        Task {
            let summary = await task.value
            if summary.wasCancelled {
                job.cancelled(summary.activityResult)
            } else {
                job.finish(summary.activityResult)
            }
            self.lastSummary = summary
            self.isRunning = false
            self.task = nil
            onEnd?(summary)
        }
        return task
    }

    /// Cancel: no new file starts; the files being converted finish.
    func cancel() {
        task?.cancel()
    }
}
