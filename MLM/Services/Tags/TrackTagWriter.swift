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
}

/// Receives the file's own values of `needOriginals` before the first write (nil = absent).
typealias TagOriginalsCapture = @Sendable ([TrackTagField: String?]) async throws -> Void

/// Why a write didn't happen. The original file is untouched in every case.
enum TagWriteFailure: Error, Sendable, Equatable {
    /// WAV, AIFF, OGG… — the database stays the truth.
    case unsupportedFormat(String)
    /// The resolved file (symlinks followed) isn't inside the library folder.
    case outsideLibraryFolder
    /// The library folder is reachable but the file isn't there: stays queued.
    case fileMissing
    /// The library folder went away: the whole run stops.
    case libraryFolderUnreachable
    /// ffmpeg / ffprobe not found.
    case toolMissing
    /// ffmpeg couldn't produce the rewritten copy.
    case rewriteFailed(String)
    /// The copy differs in more than the tags (or the tags didn't read back): not used.
    case verificationFailed(String)
    /// Something else changed the file while its tags were written.
    case fileChangedDuringWrite
    /// The verified copy couldn't take the original's place.
    case replaceFailed(String)

    /// The cause in plain words, for `Tags of 2 files couldn’t be written — ‹reason›`.
    var reason: String {
        switch self {
        case .unsupportedFormat(let name): "\(name) isn’t supported"
        case .outsideLibraryFolder: "the file isn’t inside the library folder"
        case .fileMissing: "the file is missing"
        case .libraryFolderUnreachable: "the library folder isn’t reachable"
        case .toolMissing: "ffmpeg isn’t installed"
        case .rewriteFailed: "ffmpeg couldn’t rewrite the file"
        case .verificationFailed: "rewriting would have changed more than the tags"
        case .fileChangedDuringWrite: "the file changed while its tags were written"
        case .replaceFailed: "the file couldn’t be replaced"
        }
    }

    /// Retrying won't help until the next edit (or a change outside MLM).
    var isPermanent: Bool {
        switch self {
        case .unsupportedFormat, .outsideLibraryFolder, .verificationFailed: true
        case .fileMissing, .libraryFolderUnreachable, .toolMissing, .rewriteFailed,
             .fileChangedDuringWrite, .replaceFailed: false
        }
    }

    /// Detail for the log.
    var detail: String {
        switch self {
        case .rewriteFailed(let text), .verificationFailed(let text), .replaceFailed(let text): "\(reason): \(text)"
        default: reason
        }
    }
}

enum TagWriteOutcome: Sendable, Equatable {
    /// The file now carries the values.
    case written
    /// None of the fields can go into this format (BPM in M4A): nothing to do.
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

/// Writes tags into an audio file **without re-encoding audio** (THOUGHTS §10 Q7, W2-E D).
///
/// Safety steps, in order — any failure leaves the original untouched and removes the copy:
/// 1. The file must be a regular file inside the library folder (symlinks resolved) and its
///    format one of `TagFileFormat`.
/// 2. Probe the original: streams, duration, every tag; hash every stream's packets
///    (`-f streamhash`) — audio *and* embedded cover art.
/// 3. ffmpeg copies all streams (`-map 0 -c copy`, `-map_metadata 0`) into a hidden temporary
///    file **in the same folder**, setting only the requested tags. M4A: `ipod` muxer, once
///    more with `mp4` if that refuses (exit 234, seen with PNG covers).
/// 4. Verify the copy: it opens; same streams, codecs, sample rates and channels; duration
///    within 50 ms; every stream hash identical (audio data and cover bytes unchanged, cover
///    still an attached picture); each written tag reads back equal (removed ones absent);
///    **every other tag unchanged** (only `encoder` and the MP4 brand keys may differ).
/// 5. The original must not have changed meanwhile (size, modification date).
/// 6. Atomic replace: `rename(2)` of the copy over the original (same folder, same volume),
///    with the original's permissions.
///
/// Never writes provenance or an import-normalised database value: the targets are typed values
/// or the file's own captured originals (B1).
struct TrackTagWriter: Sendable {
    let tools: any TagToolRunner
    /// Replace step (injected to simulate a failing rename in tests).
    var replace: @Sendable (_ temporary: URL, _ original: URL) throws -> Void = { try TrackTagWriter.atomicReplace($0, $1) }

    init(tools: any TagToolRunner = LiveTagToolRunner()) {
        self.tools = tools
    }

    /// Keys whose value describes the writing tool or container, allowed to differ.
    static let volatileKeys: Set<String> = ["encoder", "major_brand", "minor_version", "compatible_brands"]

    /// Duration tolerance (stream packets must be identical anyway).
    static let durationTolerance: Double = 0.05

    /// Prefix of the temporary copy: `.‹name›.mlm-tags-‹uuid›.‹ext›`.
    static let temporaryMarker = ".mlm-tags-"

    // MARK: Write

    func write(_ request: TagWriteRequest, captureOriginals: @escaping TagOriginalsCapture = { _ in }) async -> TagWriteOutcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: request.libraryRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(.libraryFolderUnreachable)
        }
        guard fm.fileExists(atPath: request.fileURL.path, isDirectory: &isDirectory) else { return .failed(.fileMissing) }
        let original = request.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard !isDirectory.boolValue, Self.isInside(original, root: request.libraryRoot) else {
            return .failed(.outsideLibraryFolder)
        }
        guard let attributes = try? fm.attributesOfItem(atPath: original.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return .failed(.outsideLibraryFolder)
        }
        guard let format = TagFileFormat(fileURL: original) else {
            return .failed(.unsupportedFormat(TagFileFormat.displayName(pathExtension: original.pathExtension)))
        }
        guard TrackTagField.allCases.contains(where: { request.targets[$0] != nil && format.metadataKey($0) != nil }) else {
            return .nothingToWrite
        }
        guard let ffmpeg = tools.path(of: .ffmpeg), let ffprobe = tools.path(of: .ffprobe) else {
            return .failed(.toolMissing)
        }

        Self.removeLeftoverCopies(of: original)
        let stamp = Self.fileStamp(attributes)

        // 2. The original as it is.
        let before: ProbeResult
        let beforeHashes: [String]
        do {
            before = try await probe(original, ffprobe: ffprobe)
            beforeHashes = try await streamHashes(original, ffmpeg: ffmpeg)
        } catch let failure as TagWriteFailure {
            return .failed(failure)
        } catch {
            return .failed(.rewriteFailed("couldn’t read the original: \(error)"))
        }
        guard before.streams.contains(where: { $0.type == "audio" }) else {
            return .failed(.verificationFailed("no audio stream in the original"))
        }

        // The file's own values, kept before MLM writes anything (B1).
        let current = Self.currentValues(before.tags, format: format)
        let originals = request.needOriginals.reduce(into: [TrackTagField: String?]()) { result, field in
            if format.metadataKey(field) != nil { result[field] = .some(current[field] ?? nil) }
        }
        do {
            try await captureOriginals(originals)
        } catch {
            return .failed(.rewriteFailed("couldn’t keep the file’s original values: \(error)"))
        }
        let changes = Self.changes(request.targets, current: current, format: format)
        guard !changes.isEmpty else { return .nothingToWrite }

        // 3. The rewritten copy, next to the original.
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
                changes: changes, id3Version: Self.id3Version(of: original), hasID3v1: Self.hasID3v1(original)
            )
            do {
                let result = try await tools.run(ffmpeg, arguments: arguments)
                if result.isSuccess, fm.fileExists(atPath: temporary.path) {
                    rewritten = true
                    break
                }
                lastError = "exit \(result.exitCode): \(result.stderr.suffix(300))"
                try? fm.removeItem(at: temporary)
                // Only the "muxer refused the streams" case (234 = EINVAL) gets the mp4 retry.
                if result.exitCode != 234 { break }
            } catch {
                lastError = "\(error)"
                break
            }
        }
        guard rewritten else {
            guard fm.fileExists(atPath: request.libraryRoot.path) else { return .failed(.libraryFolderUnreachable) }
            return .failed(.rewriteFailed(lastError))
        }

        // 4. Verify the copy.
        do {
            let after = try await probe(temporary, ffprobe: ffprobe)
            let afterHashes = try await streamHashes(temporary, ffmpeg: ffmpeg)
            if let problem = Self.verify(before: before, beforeHashes: beforeHashes,
                                          after: after, afterHashes: afterHashes,
                                          changes: changes, format: format) {
                return .failed(.verificationFailed(problem))
            }
        } catch {
            return .failed(.verificationFailed("the copy couldn’t be read: \(error)"))
        }

        // 5. Nobody changed the original meanwhile.
        guard let now = try? fm.attributesOfItem(atPath: original.path), Self.fileStamp(now) == stamp else {
            guard fm.fileExists(atPath: request.libraryRoot.path) else { return .failed(.libraryFolderUnreachable) }
            return .failed(.fileChangedDuringWrite)
        }

        // 6. Atomic replace with the original's permissions.
        if let permissions = attributes[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        do {
            try replace(temporary, original)
        } catch {
            return .failed(.replaceFailed("\(error)"))
        }
        return .written
    }

    // MARK: Values

    /// The file's current value per field (nil = absent).
    static func currentValues(_ tags: [String: String], format: TagFileFormat) -> [TrackTagField: String?] {
        var values: [TrackTagField: String?] = [:]
        for field in TrackTagField.allCases {
            guard let key = format.metadataKey(field) else { continue }
            values[field] = .some(tags[key.lowercased()])
        }
        return values
    }

    /// The `-metadata` changes for `targets`. A field whose file value already equals the
    /// target is left alone; a typed year that is the year of the file's full date
    /// (`2019` vs `2019-05-03`) keeps the date.
    static func changes(
        _ targets: [TrackTagField: TagFileTarget],
        current: [TrackTagField: String?],
        format: TagFileFormat
    ) -> [(key: String, value: String?)] {
        var changes: [(key: String, value: String?)] = []
        for field in TrackTagField.allCases {
            guard let target = targets[field], let key = format.metadataKey(field) else { continue }
            let existing = current[field] ?? nil
            if existing == target.value { continue }
            if field == .year, case .typed(let year?) = target, let existing, existing.hasPrefix(year + "-") { continue }
            changes.append((key, target.value))
        }
        return changes
    }

    // MARK: Steps

    /// `rename(2)`: atomic within one volume; the original stays until the copy takes its name.
    static func atomicReplace(_ temporary: URL, _ original: URL) throws {
        guard Darwin.rename(temporary.path, original.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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

    private static func fileStamp(_ attributes: [FileAttributeKey: Any]) -> String {
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        return "\(size)|\(modified)"
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
        hasID3v1: Bool
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
            arguments += ["-id3v2_version", String(id3Version), "-write_id3v1", hasID3v1 ? "1" : "0"]
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
    }

    struct ProbeResult: Equatable, Sendable {
        let duration: Double?
        /// Format tags, keys lower-cased.
        let tags: [String: String]
        let streams: [ProbeStream]
    }

    /// Probe into a private file (`-o`), not a pipe: a pipe read racing the process exit could
    /// hand back partial JSON under load.
    func probe(_ url: URL, ffprobe: String) async throws -> ProbeResult {
        let output = Self.scratchFile("probe", ext: "json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await tools.run(ffprobe, arguments: [
            "-v", "error",
            "-show_entries", "format=duration:format_tags:stream=index,codec_type,codec_name,sample_rate,channels:stream_disposition=attached_pic",
            "-of", "json",
            "-o", output.path,
            Self.ffmpegPath(url),
        ])
        guard result.isSuccess, let json = try? String(contentsOf: output, encoding: .utf8),
              let probe = Self.parseProbe(json) else {
            throw TagWriteFailure.rewriteFailed("ffprobe couldn’t read \(url.lastPathComponent): exit \(result.exitCode) \(result.stderr.suffix(200))")
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
        var tags: [String: String] = [:]
        for (key, value) in format["tags"] as? [String: Any] ?? [:] {
            tags[key.lowercased()] = "\(value)"
        }
        let streams: [ProbeStream] = (object["streams"] as? [[String: Any]] ?? []).map { stream in
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            return ProbeStream(
                index: stream["index"] as? Int ?? -1,
                type: stream["codec_type"] as? String ?? "",
                codec: stream["codec_name"] as? String ?? "",
                sampleRate: stream["sample_rate"] as? String,
                channels: stream["channels"] as? Int,
                attachedPicture: (disposition["attached_pic"] as? Int) == 1
            )
        }
        return ProbeResult(duration: duration, tags: tags, streams: streams)
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
            throw TagWriteFailure.rewriteFailed("couldn’t hash \(url.lastPathComponent): exit \(result.exitCode) \(result.stderr.suffix(200))")
        }
        return lines
    }

    // MARK: Verify

    /// `nil` when the copy differs from the original in exactly the requested tags.
    static func verify(
        before: ProbeResult,
        beforeHashes: [String],
        after: ProbeResult,
        afterHashes: [String],
        changes: [(key: String, value: String?)],
        format: TagFileFormat
    ) -> String? {
        guard before.streams.count == after.streams.count else {
            return "stream count \(before.streams.count) → \(after.streams.count)"
        }
        for (old, new) in zip(before.streams, after.streams) {
            guard old.type == new.type, old.codec == new.codec, old.sampleRate == new.sampleRate,
                  old.channels == new.channels, old.attachedPicture == new.attachedPicture else {
                return "stream \(old.index) changed (\(old.type) \(old.codec) → \(new.type) \(new.codec))"
            }
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
