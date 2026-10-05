import Foundation
import Testing
@testable import MLM

/// Audio files generated with ffmpeg inside a temporary folder — the only files tag-writing
/// tests ever touch. Tests needing the tools are disabled (with this reason) when they're
/// missing.
enum TagTestFixtures {
    static let ffmpeg = ProcessRunner.findExecutable("ffmpeg")
    static let ffprobe = ProcessRunner.findExecutable("ffprobe")
    static var toolsAvailable: Bool { ffmpeg != nil && ffprobe != nil }
    static let skipReason: Comment = "ffmpeg and ffprobe are needed to generate and check audio files; neither was found in the usual places"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A fresh folder under the system temporary directory.
    static func makeFolder(_ label: String = "tags") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLM-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    static func ffmpegRun(_ arguments: [String]) async throws -> ProcessRunner.ProcessResult {
        guard let ffmpeg else { throw Failure(description: "ffmpeg missing") }
        let result = try await ProcessRunner.run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-v", "error", "-y"] + arguments)
        guard result.isSuccess else { throw Failure(description: "ffmpeg failed: \(result.stderr)") }
        return result
    }

    /// A 64×64 single-colour picture.
    static func cover(in folder: URL, png: Bool) async throws -> URL {
        let url = folder.appendingPathComponent(png ? "cover.png" : "cover.jpg")
        try await ffmpegRun(["-f", "lavfi", "-i", png ? "color=c=red:s=64x64" : "color=c=blue:s=64x64", "-frames:v", "1", url.path])
        return url
    }

    enum Kind {
        case m4aAAC, m4aALAC, mp3, flac, wav

        var fileExtension: String {
            switch self {
            case .m4aAAC, .m4aALAC: "m4a"
            case .mp3: "mp3"
            case .flac: "flac"
            case .wav: "wav"
            }
        }

        var codecArguments: [String] {
            switch self {
            case .m4aAAC: ["-c:a", "aac", "-b:a", "96k"]
            case .m4aALAC: ["-c:a", "alac"]
            case .mp3: ["-c:a", "libmp3lame", "-b:a", "96k", "-id3v2_version", "3"]
            case .flac: ["-c:a", "flac"]
            case .wav: ["-c:a", "pcm_s16le"]
            }
        }
    }

    /// A 2-second sine with `tags`, optionally an attached cover, plus muxer `extra` arguments.
    static func audio(
        _ kind: Kind,
        in folder: URL,
        name: String = "track",
        cover: URL? = nil,
        tags: [String: String] = [:],
        extra: [String] = []
    ) async throws -> URL {
        let url = folder.appendingPathComponent("\(name).\(kind.fileExtension)")
        var arguments = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
        if let cover {
            arguments += ["-i", cover.path, "-map", "0:a", "-map", "1:v", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        arguments += kind.codecArguments
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            arguments += ["-metadata", "\(key)=\(value)"]
        }
        arguments += extra + [url.path]
        try await ffmpegRun(arguments)
        return url
    }

    /// Format tags, keys lower-cased.
    static func tags(of url: URL) async throws -> [String: String] {
        try await probe(url).tags
    }

    static func probe(_ url: URL) async throws -> TrackTagWriter.ProbeResult {
        guard let ffprobe else { throw Failure(description: "ffprobe missing") }
        return try await TrackTagWriter(tools: LiveTagToolRunner()).probe(url, ffprobe: ffprobe)
    }

    /// Packet hashes of every stream (`index,type,MD5=…`).
    static func hashes(of url: URL) async throws -> [String] {
        guard let ffmpeg else { throw Failure(description: "ffmpeg missing") }
        return try await TrackTagWriter(tools: LiveTagToolRunner()).streamHashes(url, ffmpeg: ffmpeg)
    }

    /// Names in `folder` that aren't `expected` (left-over temporary copies).
    static func strayFiles(in folder: URL, expected: Set<String>) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !expected.contains($0) }.sorted()
    }
}

/// The real tools, with a hook to change a call's result (simulated failures).
struct ScriptedTagToolRunner: TagToolRunner {
    var live = LiveTagToolRunner()
    var missingTools: Set<TagTool> = []
    /// Called before each run; return a result to use instead of running the tool.
    var before: @Sendable (_ executable: String, _ arguments: [String]) -> ProcessRunner.ProcessResult? = { _, _ in nil }
    /// Called after each real run (e.g. to damage the output).
    var after: @Sendable (_ executable: String, _ arguments: [String]) -> Void = { _, _ in }

    func path(of tool: TagTool) -> String? {
        missingTools.contains(tool) ? nil : live.path(of: tool)
    }

    func run(_ executable: String, arguments: [String]) async throws -> ProcessRunner.ProcessResult {
        if let scripted = before(executable, arguments) { return scripted }
        let result = try await live.run(executable, arguments: arguments)
        after(executable, arguments)
        return result
    }

    static func result(exit: Int32, stderr: String = "") -> ProcessRunner.ProcessResult {
        ProcessRunner.ProcessResult(exitCode: exit, stdout: "", stderr: stderr, timedOut: false, processIdentifier: 0)
    }

    /// The output path of an ffmpeg rewrite call (`-f ‹muxer› file:‹path›`), nil for other calls.
    static func rewriteOutput(_ arguments: [String]) -> URL? {
        guard arguments.contains("-map_metadata"), let last = arguments.last, last.hasPrefix("file:") else { return nil }
        return URL(fileURLWithPath: String(last.dropFirst("file:".count)))
    }
}

extension TagWriteRequest {
    /// Typed values for every field in `values` (nil = no tag) — the shape of a plain edit.
    init(fileURL: URL, libraryRoot: URL, values: [TrackTagField: String?]) {
        self.init(fileURL: fileURL, libraryRoot: libraryRoot, targets: values.mapValues { TagFileTarget.typed($0) })
    }
}
