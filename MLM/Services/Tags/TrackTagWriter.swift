import Darwin
import Foundation

// MARK: - Request and outcome

/// What one field of a file gets (W2-E review B1): a value the user typed, or the exact value
/// the file had before MLM's first write. `nil` = no tag.
enum TagFileTarget: Sendable, Equatable {
    case typed(String?)
    case restore(String?)

    var value: String? {
        switch self {
        case .typed(let value), .restore(let value): value
        }
    }
}

/// One file's tag write.
struct TagWriteRequest: Sendable {
    let fileURL: URL
    /// The library folder; the writer refuses any file outside it.
    let libraryRoot: URL
    let targets: [TrackTagField: TagFileTarget]
    /// Fields whose pre-MLM value isn't captured yet: read from the file and handed to
    /// `captureOriginals` **before** anything is written.
    var needOriginals: Set<TrackTagField> = []
    /// `tracks.duration` (seconds): the file must be within 2 s of it (S2); nil = unknown.
    var expectedDuration: Int?
    /// `tracks.format` as stored (`mp3`, `m4a`, `aac`, `flac`…): the file must be that format.
    var expectedFormat: String?
}

/// Receives the file's own values of `needOriginals` before the first write (nil = absent).
typealias TagOriginalsCapture = @Sendable ([TrackTagField: String?]) async throws -> Void

/// Why a write didn't happen. The original file is untouched in every case.
enum TagWriteFailure: Error, Sendable, Equatable {
    /// WAV, AIFF, OGG… — the database stays the truth.
    case unsupportedFormat(String)
    /// The file holds tag data a rewrite can't keep intact (B2): `Serato markers`, `GEOB`…
    case cannotPreserve(String)
    /// The resolved file (symlinks followed) isn't inside the library folder.
    case outsideLibraryFolder
    /// Other hard links point at the file: replacing it would split them.
    case hardLinked
    /// Duration or format don't match the track (another disk at the root, a stale path; S2).
    case notThisTracksFile(String)
    /// The library folder is reachable but the file isn't there: stays queued.
    case fileMissing
    /// The library folder went away: the whole run stops.
    case libraryFolderUnreachable
    /// ffmpeg / ffprobe not found: the run stops, nothing is counted.
    case toolMissing
    /// The write was cancelled (unmount, setting off, quit): tried again later.
    case cancelled
    /// ffmpeg couldn't produce the rewritten copy, or the original couldn't be read.
    case rewriteFailed(String)
    /// The rewritten copy couldn't be checked (a probe failed or timed out): tried again later.
    case checkFailed(String)
    /// The copy differs in more than the tags: refused for good (until the next edit).
    case verificationFailed(String)
    /// Something else changed the file while its tags were written.
    case fileChangedDuringWrite
    /// Another program holds a lock on the file.
    case fileInUse
    /// The verified copy couldn't take the original's place.
    case replaceFailed(String)

    /// The cause in plain words, for `Tags of 2 files couldn’t be written — ‹reason›`.
    var reason: String {
        switch self {
        case .unsupportedFormat(let name): "\(name) isn’t supported"
        case .cannotPreserve(let what): "it contains tag data MLM can’t preserve (\(what))"
        case .outsideLibraryFolder: "the file isn’t inside the library folder"
        case .hardLinked: "the file has other hard links"
        case .notThisTracksFile: "the file doesn’t look like this track’s file"
        case .fileMissing: "file not found"
        case .libraryFolderUnreachable: "the library folder isn’t reachable"
        case .toolMissing: "ffmpeg isn’t installed"
        case .cancelled: "the write was stopped"
        case .rewriteFailed: "ffmpeg couldn’t rewrite the file"
        case .checkFailed: "the rewritten file couldn’t be checked"
        case .verificationFailed: "rewriting would have changed more than the tags"
        case .fileChangedDuringWrite: "the file changed while its tags were written"
        case .fileInUse: "the file is in use by another app"
        case .replaceFailed: "the file couldn’t be replaced"
        }
    }

    /// Retrying won't help until the next edit (or `Try Again` after a change outside MLM).
    var isPermanent: Bool {
        switch self {
        case .unsupportedFormat, .cannotPreserve, .outsideLibraryFolder, .hardLinked, .notThisTracksFile, .verificationFailed:
            true
        case .fileMissing, .libraryFolderUnreachable, .toolMissing, .cancelled, .rewriteFailed, .checkFailed,
             .fileChangedDuringWrite, .fileInUse, .replaceFailed:
            false
        }
    }

    /// Detail for the log.
    var detail: String {
        switch self {
        case .rewriteFailed(let text), .checkFailed(let text), .verificationFailed(let text),
             .replaceFailed(let text), .notThisTracksFile(let text):
            "\(reason): \(text)"
        default: reason
        }
    }
}

enum TagWriteOutcome: Sendable, Equatable {
    /// The file now carries the values.
    case written
    /// Nothing to change (the file already has the values, or the format can't take them).
    case nothingToWrite
    case failed(TagWriteFailure)
}

// MARK: - Tools

/// Runs ffmpeg / ffprobe (injected so tests can simulate failures).
protocol TagToolRunner: Sendable {
    func path(of tool: TagTool) -> String?
    func run(_ executable: String, arguments: [String]) async throws -> ProcessRunner.ProcessResult
}

enum TagTool: String, Sendable {
    case ffmpeg
    case ffprobe
}

/// The real tools through the existing lookup (`ProcessRunner.findExecutable`, the same search
/// paths `ExternalToolHealth` reports in Settings ▸ Sources).
struct LiveTagToolRunner: TagToolRunner {
    /// Per process; a tag rewrite copies the file once.
    var timeout: TimeInterval = 600

    func path(of tool: TagTool) -> String? {
        ProcessRunner.findExecutable(tool.rawValue)
    }

    func run(_ executable: String, arguments: [String]) async throws -> ProcessRunner.ProcessResult {
        try await ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
    }
}

// MARK: - Writer

/// Writes tags into an audio file **without re-encoding audio** (THOUGHTS §10 Q7), only when
/// nothing else in the file can be lost. Any failure leaves the original untouched and removes
/// the copy. Steps:
/// 1. Regular file inside the library folder (symlinks resolved), one hard link, a supported
///    format; one writer per path (`LibraryFileLock`) plus an advisory `flock`.
/// 2. **Raw tag inventory** (`TagInventoryReader`, B2): every ID3 frame / MP4 atom / FLAC block
///    and Vorbis key must be on the verified allow-list (`TagAllowList`), else refused for good
///    with the reason (`Serato markers`, `GEOB`, a seek table…).
/// 3. Probe and hash every stream's packets; the file must be this track's (duration ±2 s,
///    format) (S2). The file's own values of first-written fields are handed to
///    `captureOriginals` before anything is written (B1).
/// 4. ffmpeg copies all streams (`-map 0 -c copy`) into a hidden copy in the same folder,
///    setting only the requested tags (MP3 keeps its ID3 version, ID3v1 and Xing-or-not).
/// 5. Verify the copy: same streams, codecs, start times, durations, stream tags (picture
///    type), identical packet hashes (audio and covers), same gapless information; the raw
///    inventory equal except the edited items (each reading back as requested) and the
///    writer's own name; ffprobe's tags likewise.
/// 6. Re-check the original (size, modification date, inode), copy its extended attributes,
///    ACLs, permissions and creation date onto the copy (S7), atomic `rename(2)`.
///
/// Never writes provenance or an import-normalised database value: targets are typed values
/// or the file's own captured originals.
struct TrackTagWriter: Sendable {
    let tools: any TagToolRunner
    /// Replace step (injected to simulate a failing rename in tests).
    var replace: @Sendable (_ temporary: URL, _ original: URL) throws -> Void = { try TrackTagWriter.atomicReplace($0, $1) }

    init(tools: any TagToolRunner = LiveTagToolRunner()) {
        self.tools = tools
    }

    /// ffprobe keys describing the writing tool or container, allowed to differ.
    static let volatileKeys: Set<String> = ["encoder", "major_brand", "minor_version", "compatible_brands"]
    /// Stream-level tags allowed to differ.
    static let volatileStreamKeys: Set<String> = ["encoder"]

    /// Duration tolerance of the copy (stream packets must be identical anyway).
    static let durationTolerance: Double = 0.05
    /// How far the file may be from `tracks.duration` (S2).
    static let trackDurationTolerance: Double = 2

    /// Prefix of the temporary copy: `.‹name›.mlm-tags-‹uuid›.‹ext›`.
    static let temporaryMarker = ".mlm-tags-"

    // MARK: Write

    func write(_ request: TagWriteRequest, captureOriginals: @escaping TagOriginalsCapture = { _ in }) async -> TagWriteOutcome {
        let fm = FileManager.default
        let root = request.libraryRoot
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(.libraryFolderUnreachable)
        }
        guard fm.fileExists(atPath: request.fileURL.path, isDirectory: &isDirectory) else { return .failed(.fileMissing) }
        let original = request.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard !isDirectory.boolValue, Self.isInside(original, root: root) else {
            return .failed(.outsideLibraryFolder)
        }
        guard let attributes = try? fm.attributesOfItem(atPath: original.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return .failed(.outsideLibraryFolder)
        }
        if let links = attributes[.referenceCount] as? NSNumber, links.intValue > 1 { return .failed(.hardLinked) }
        guard let format = TagFileFormat(fileURL: original) else {
            return .failed(.unsupportedFormat(TagFileFormat.displayName(pathExtension: original.pathExtension)))
        }
        guard TrackTagField.allCases.contains(where: { request.targets[$0] != nil && format.metadataKey($0) != nil }) else {
            return .nothingToWrite
        }
        guard let ffmpeg = tools.path(of: .ffmpeg), let ffprobe = tools.path(of: .ffprobe) else {
            return .failed(.toolMissing)
        }

        await LibraryFileLock.shared.acquire(original.path)
        let outcome = await locked(request, original: original, format: format, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                   captureOriginals: captureOriginals)
        await LibraryFileLock.shared.release(original.path)
        return outcome
    }

    private func locked(
        _ request: TagWriteRequest,
        original: URL,
        format: TagFileFormat,
        ffmpeg: String,
        ffprobe: String,
        captureOriginals: TagOriginalsCapture
    ) async -> TagWriteOutcome {
        let fm = FileManager.default
        let root = request.libraryRoot
        // An advisory lock for other cooperating programs; held until the swap.
        let descriptor = open(original.path, O_RDONLY)
        guard descriptor >= 0 else { return .failed(classify(TagWriteFailure.fileMissing, root: root)) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return .failed(.fileInUse) }
        guard let stamp = Self.fileStamp(original) else { return .failed(classify(TagWriteFailure.fileMissing, root: root)) }

        Self.removeLeftoverCopies(of: original)

        // 2. The raw tag structure.
        let before: TagInventory
        do {
            before = try TagInventoryReader.read(fileURL: original, format: format)
        } catch {
            return .failed(classify(.rewriteFailed("couldn’t read the tags: \(error)"), root: root))
        }
        if let refusal = before.refusal { return .failed(.cannotPreserve(refusal)) }

        // 3. Streams, and whether this is the track's file.
        let probed: ProbeResult
        let hashes: [String]
        do {
            probed = try await probe(original, ffprobe: ffprobe)
            hashes = try await streamHashes(original, ffmpeg: ffmpeg)
        } catch {
            return .failed(classify(.rewriteFailed("couldn’t read the original: \(error)"), root: root))
        }
        if probed.ambiguousKeys { return .failed(.cannotPreserve("tags that differ only in letter case")) }
        guard probed.streams.contains(where: { $0.type == "audio" }) else {
            return .failed(.notThisTracksFile("no audio stream"))
        }
        if let problem = Self.trackMismatch(request, probed: probed, format: format) {
            return .failed(.notThisTracksFile(problem))
        }

        let current = Self.currentValues(before, format: format)
        let originals = request.needOriginals.reduce(into: [TrackTagField: String?]()) { result, field in
            if format.metadataKey(field) != nil { result[field] = .some(current[field] ?? nil) }
        }
        do {
            try await captureOriginals(originals)
        } catch {
            return .failed(classify(.rewriteFailed("couldn’t keep the file’s original values: \(error)"), root: root))
        }
        let changes = Self.changes(request.targets, current: current, format: format)
        guard !changes.isEmpty else { return .nothingToWrite }
        guard !Task.isCancelled else { return .failed(.cancelled) }

        // 4. The rewritten copy, next to the original.
        let temporary = original.deletingLastPathComponent()
            .appendingPathComponent(".\(original.lastPathComponent)\(Self.temporaryMarker)\(UUID().uuidString).\(original.pathExtension)")
        defer { try? fm.removeItem(at: temporary) }
        var muxers = [format.muxer]
        if format == .m4a { muxers.append("mp4") }
        var lastError = ""
        var rewritten = false
        for muxer in muxers {
            let arguments = Self.rewriteArguments(
                input: original, output: temporary, format: format, muxer: muxer,
                changes: changes.map { ($0.key, $0.value) }, id3Version: before.id3Version ?? 3,
                hasID3v1: before.id3v1 != nil, writeXing: before.gapless != "none"
            )
            do {
                let result = try await tools.run(ffmpeg, arguments: arguments)
                if result.isSuccess, fm.fileExists(atPath: temporary.path) {
                    rewritten = true
                    break
                }
                lastError = result.timedOut ? "timed out" : "exit \(result.exitCode): \(result.stderr.suffix(300))"
                try? fm.removeItem(at: temporary)
                // Only the "muxer refused the streams" case (234 = EINVAL) gets the mp4 retry.
                if result.exitCode != 234 { break }
            } catch {
                lastError = "\(error)"
                break
            }
        }
        guard rewritten else { return .failed(classify(.rewriteFailed(lastError), root: root)) }

        // 5. Verify the copy.
        let checkedProbe: ProbeResult
        let checkedHashes: [String]
        let checkedInventory: TagInventory
        do {
            checkedProbe = try await probe(temporary, ffprobe: ffprobe)
            checkedHashes = try await streamHashes(temporary, ffmpeg: ffmpeg)
            checkedInventory = try TagInventoryReader.read(fileURL: temporary, format: format)
        } catch {
            return .failed(classify(.checkFailed("\(error)"), root: root))
        }
        let ffmpegChanges = changes.map { ($0.key, $0.value) }
        if let problem = Self.verify(before: probed, beforeHashes: hashes, after: checkedProbe, afterHashes: checkedHashes,
                                      changes: ffmpegChanges, format: format) {
            return .failed(.verificationFailed(problem))
        }
        let expected = Dictionary(uniqueKeysWithValues: changes.compactMap { change -> (String, String?)? in
            format.rawKey(change.field, id3Version: before.id3Version ?? 3).map { ($0, change.value) }
        })
        let editedV1 = changes.reduce(into: Set<String>()) { $0.formUnion(TagInventoryComparison.v1Fields($1.field)) }
        if let problem = TagInventoryComparison.problem(before: before, after: checkedInventory, expected: expected, editedV1: editedV1) {
            return .failed(.verificationFailed(problem))
        }

        // 6. Nobody changed the original meanwhile; swap with its metadata.
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard Self.fileStamp(original) == stamp else {
            return .failed(classify(.fileChangedDuringWrite, root: root))
        }
        do {
            try Self.copyFileMetadata(from: original, to: temporary)
            try replace(temporary, original)
        } catch {
            return .failed(classify(.replaceFailed("\(error)"), root: root))
        }
        return .written
    }

    /// A failure while the folder is gone is the folder's (not the file's); a cancelled task
    /// is a stop, not an error (S1).
    private func classify(_ failure: TagWriteFailure, root: URL) -> TagWriteFailure {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return .libraryFolderUnreachable
        }
        if Task.isCancelled { return .cancelled }
        return failure
    }

    // MARK: Values

    /// The file's current value per field from its raw tags (nil = absent).
    static func currentValues(_ inventory: TagInventory, format: TagFileFormat) -> [TrackTagField: String?] {
        var values: [TrackTagField: String?] = [:]
        for field in TrackTagField.allCases {
            guard format.metadataKey(field) != nil, let key = format.rawKey(field, id3Version: inventory.id3Version) else { continue }
            values[field] = .some(inventory.value(key))
        }
        return values
    }

    /// The changes for `targets`. A field whose file value already equals the target is left
    /// alone; a typed year that is the year of the file's full date (`2019` vs `2019-05-03`)
    /// keeps the date.
    static func changes(
        _ targets: [TrackTagField: TagFileTarget],
        current: [TrackTagField: String?],
        format: TagFileFormat
    ) -> [(field: TrackTagField, key: String, value: String?)] {
        var changes: [(field: TrackTagField, key: String, value: String?)] = []
        for field in TrackTagField.allCases {
            guard let target = targets[field], let key = format.metadataKey(field) else { continue }
            let existing = current[field] ?? nil
            if existing == target.value { continue }
            if field == .year, case .typed(let year?) = target, let existing, existing.hasPrefix(year + "-") { continue }
            changes.append((field, key, target.value))
        }
        return changes
    }

    /// Why the file isn't this track's (S2): its duration is more than 2 s from
    /// `tracks.duration`, or its format isn't the stored one. nil = it matches (or can't tell).
    static func trackMismatch(_ request: TagWriteRequest, probed: ProbeResult, format: TagFileFormat) -> String? {
        if let expected = request.expectedDuration, expected > 0, let actual = probed.duration,
           abs(actual - Double(expected)) > trackDurationTolerance {
            return "duration \(Int(actual.rounded())) s, the track has \(expected) s"
        }
        if let stored = request.expectedFormat?.trimmingCharacters(in: .whitespaces).lowercased(), !stored.isEmpty {
            let storedFormat = TagFileFormat(pathExtension: stored) ?? (["aac", "alac", "mp4"].contains(stored) ? .m4a : nil)
            if let storedFormat, storedFormat != format { return "the file is \(format.displayName), the track is \(stored.uppercased())" }
        }
        return nil
    }

    // MARK: Steps

    /// `rename(2)`: atomic within one volume; the original stays until the copy takes its name.
    static func atomicReplace(_ temporary: URL, _ original: URL) throws {
        guard Darwin.rename(temporary.path, original.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// The original's extended attributes (Finder tags and comments, where-froms), ACL,
    /// permissions and creation date onto the copy (S7). The modification date is the copy's
    /// own: the file did change.
    static func copyFileMetadata(from original: URL, to copy: URL) throws {
        guard copyfile(original.path, copy.path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        var keep: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] { keep[.posixPermissions] = permissions }
        if let created = attributes[.creationDate] { keep[.creationDate] = created }
        if !keep.isEmpty { try FileManager.default.setAttributes(keep, ofItemAtPath: copy.path) }
    }

    static func isInside(_ file: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) && filePath.count > prefix.count
    }

    /// Copies left behind by an interrupted write (the drive went away mid-run).
    static func removeLeftoverCopies(of original: URL) {
        let folder = original.deletingLastPathComponent()
        let prefix = ".\(original.lastPathComponent)\(temporaryMarker)"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Size, modification time and inode: re-checked right before the swap.
    static func fileStamp(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ino)|\(info.st_dev)"
    }

    /// `file:` keeps ffmpeg from reading a `:` in a folder name as a protocol.
    static func ffmpegPath(_ url: URL) -> String { "file:" + url.path }

    static func rewriteArguments(
        input: URL,
        output: URL,
        format: TagFileFormat,
        muxer: String,
        changes: [(key: String, value: String?)],
        id3Version: Int,
        hasID3v1: Bool,
        writeXing: Bool = true
    ) -> [String] {
        var arguments = [
            "-nostdin", "-hide_banner", "-v", "error", "-y",
            "-i", ffmpegPath(input),
            "-map", "0", "-c", "copy",
            "-map_metadata", "0", "-map_chapters", "0",
        ]
        for change in changes {
            // An empty value removes the key.
            arguments += ["-metadata", "\(change.key)=\(change.value ?? "")"]
        }
        switch format {
        case .m4a:
            arguments += ["-movflags", "+faststart"]
        case .mp3:
            arguments += ["-id3v2_version", String(id3Version), "-write_id3v1", hasID3v1 ? "1" : "0",
                          "-write_xing", writeXing ? "1" : "0"]
        case .flac:
            break
        }
        arguments += ["-f", muxer, ffmpegPath(output)]
        return arguments
    }

    /// ID3v2 major version of an MP3's tag (3 or 4); 3 when it has none (widest support).
    static func id3Version(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 3 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4,
              head.prefix(3) == Data("ID3".utf8) else { return 3 }
        return head[3] == 4 ? 4 : 3
    }

    /// The MP3 ends with a 128-byte ID3v1 tag.
    static func hasID3v1(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mp3", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 128 else { return false }
        try? handle.seek(toOffset: size - 128)
        guard let tail = try? handle.read(upToCount: 3) else { return false }
        return tail == Data("TAG".utf8)
    }

    // MARK: Probe

    struct ProbeStream: Equatable, Sendable {
        let index: Int
        let type: String
        let codec: String
        let sampleRate: String?
        let channels: Int?
        let attachedPicture: Bool
        var startTime: String? = nil
        var durationTS: String? = nil
        /// Stream tags (picture type `comment: Cover (front)`, language…), keys lower-cased.
        var tags: [String: String] = [:]
    }

    struct ProbeResult: Equatable, Sendable {
        let duration: Double?
        /// Format tags, keys lower-cased.
        let tags: [String: String]
        let streams: [ProbeStream]
        /// Two tags whose keys differ only in letter case: can't be verified.
        var ambiguousKeys = false
    }

    /// Probe into a private file (`-o`), not a pipe: a pipe read racing the process exit could
    /// hand back partial JSON under load.
    func probe(_ url: URL, ffprobe: String) async throws -> ProbeResult {
        let output = Self.scratchFile("probe", ext: "json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await tools.run(ffprobe, arguments: [
            "-v", "error",
            "-show_entries",
            "format=duration:format_tags:stream=index,codec_type,codec_name,sample_rate,channels,start_time,duration_ts:stream_disposition=attached_pic:stream_tags",
            "-of", "json",
            "-o", output.path,
            Self.ffmpegPath(url),
        ])
        guard result.isSuccess, let json = try? String(contentsOf: output, encoding: .utf8),
              let probe = Self.parseProbe(json) else {
            throw TagWriteFailure.checkFailed("ffprobe couldn’t read \(url.lastPathComponent): \(result.timedOut ? "timed out" : "exit \(result.exitCode)") \(result.stderr.suffix(200))")
        }
        return probe
    }

    /// A file of our own in the system temporary folder (never the library folder).
    static func scratchFile(_ kind: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mlm-tags-\(kind)-\(UUID().uuidString).\(ext)")
    }

    static func parseProbe(_ json: String) -> ProbeResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let format = object["format"] as? [String: Any] ?? [:]
        let duration = (format["duration"] as? String).flatMap(Double.init)
        var ambiguous = false
        func lowered(_ raw: [String: Any]) -> [String: String] {
            var result: [String: String] = [:]
            for (key, value) in raw {
                let lower = key.lowercased()
                if result[lower] != nil { ambiguous = true }
                result[lower] = "\(value)"
            }
            return result
        }
        let tags = lowered(format["tags"] as? [String: Any] ?? [:])
        let streams: [ProbeStream] = (object["streams"] as? [[String: Any]] ?? []).map { stream in
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            return ProbeStream(
                index: stream["index"] as? Int ?? -1,
                type: stream["codec_type"] as? String ?? "",
                codec: stream["codec_name"] as? String ?? "",
                sampleRate: stream["sample_rate"] as? String,
                channels: stream["channels"] as? Int,
                attachedPicture: (disposition["attached_pic"] as? Int) == 1,
                startTime: stream["start_time"] as? String,
                durationTS: (stream["duration_ts"] as? Int).map(String.init) ?? stream["duration_ts"] as? String,
                tags: lowered(stream["tags"] as? [String: Any] ?? [:])
            )
        }
        return ProbeResult(duration: duration, tags: tags, streams: streams, ambiguousKeys: ambiguous)
    }

    /// One `index,type,MD5=…` line per stream: the packets as stored (no decoding).
    func streamHashes(_ url: URL, ffmpeg: String) async throws -> [String] {
        let output = Self.scratchFile("hash", ext: "txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await tools.run(ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-v", "error", "-y",
            "-i", Self.ffmpegPath(url),
            "-map", "0", "-c", "copy",
            "-f", "streamhash", "-hash", "md5", Self.ffmpegPath(output),
        ])
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard result.isSuccess, !lines.isEmpty else {
            throw TagWriteFailure.checkFailed("couldn’t hash \(url.lastPathComponent): \(result.timedOut ? "timed out" : "exit \(result.exitCode)") \(result.stderr.suffix(200))")
        }
        return lines
    }

    // MARK: Verify

    /// `nil` when the copy differs from the original (as ffprobe sees it) in exactly the
    /// requested tags.
    static func verify(
        before: ProbeResult,
        beforeHashes: [String],
        after: ProbeResult,
        afterHashes: [String],
        changes: [(key: String, value: String?)],
        format: TagFileFormat
    ) -> String? {
        if after.ambiguousKeys { return "the copy has tags that differ only in letter case" }
        guard before.streams.count == after.streams.count else {
            return "stream count \(before.streams.count) → \(after.streams.count)"
        }
        for (old, new) in zip(before.streams, after.streams) {
            guard old.type == new.type, old.codec == new.codec, old.sampleRate == new.sampleRate,
                  old.channels == new.channels, old.attachedPicture == new.attachedPicture else {
                return "stream \(old.index) changed (\(old.type) \(old.codec) → \(new.type) \(new.codec))"
            }
            guard old.startTime == new.startTime, old.durationTS == new.durationTS else {
                return "stream \(old.index) timing changed"
            }
            let oldTags = old.tags.filter { !volatileStreamKeys.contains($0.key) }
            let newTags = new.tags.filter { !volatileStreamKeys.contains($0.key) }
            guard oldTags == newTags else { return "stream \(old.index) tags changed" }
        }
        guard beforeHashes == afterHashes else { return "stream data changed" }
        if let old = before.duration {
            guard let new = after.duration, abs(new - old) <= durationTolerance else {
                return "duration \(old) → \(after.duration.map { "\($0)" } ?? "none")"
            }
        }
        let written = Set(changes.map { $0.key.lowercased() })
        for change in changes {
            let key = change.key.lowercased()
            let expected = change.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let actual = after.tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard actual == expected else { return "tag \(key) reads back “\(actual)”, expected “\(expected)”" }
        }
        for (key, value) in before.tags where !written.contains(key) && !volatileKeys.contains(key) {
            guard let kept = after.tags[key] else { return "tag \(key) would be lost" }
            guard kept.trimmingCharacters(in: .whitespacesAndNewlines) == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return "tag \(key) would change"
            }
        }
        return nil
    }
}
