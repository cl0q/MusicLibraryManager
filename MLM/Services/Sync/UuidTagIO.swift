import Foundation
import AVFoundation

/// Read-back utility for MLM UUID tags embedded by `SyncService.embedMlmUuid`.
///
/// - mp3: reads the ID3 TXXX frame with description `MLM_UUID` via AVMetadataItem,
///   falling back to ffprobe if AVMetadataItem cannot decode it.
/// - m4a/aac/mp4: reads the `comment` field and parses the `MLM_UUID:` prefix.
///
/// Returns nil cleanly for files without an embedded UUID or on any read error.
enum UuidTagIO {

    /// Read the MLM UUID previously embedded into an audio file.
    /// Returns nil if the file has no embedded UUID or cannot be read.
    static func readMlmUuid(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            return await readMlmUuidFromMp3(url: url)
        case "m4a", "aac", "mp4":
            return await readMlmUuidFromM4a(url: url)
        default:
            return nil
        }
    }

    // MARK: - mp3 (ID3 TXXX)

    private static func readMlmUuidFromMp3(url: URL) async -> String? {
        // Try AVMetadataItem first — avoids shelling out when it works.
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata {
            if let key = item.key as? String, key.hasPrefix("TXXX"),
               let value = item.stringValue {
                let cleaned = value.replacingOccurrences(of: "\0", with: "")
                if cleaned.hasPrefix("MLM_UUID") {
                    let uuid = String(cleaned.dropFirst("MLM_UUID".count))
                        .trimmingCharacters(in: .whitespaces)
                    if !uuid.isEmpty { return uuid }
                }
            }
        }
        // Fallback: ffprobe
        return await readMlmUuidFromMp3ViaFfprobe(url: url)
    }

    private static func readMlmUuidFromMp3ViaFfprobe(url: URL) async -> String? {
        guard let ffprobe = ProcessRunner.findExecutable("ffprobe") else { return nil }
        // The TXXX key contains a colon (TXXX:MLM_UUID) which breaks ffprobe's
        // -show_entries selector, so fetch all format_tags as JSON and parse.
        let args = [
            "-v", "quiet",
            "-show_entries", "format_tags",
            "-of", "json",
            url.path,
        ]
        do {
            let result = try await ProcessRunner.run(ffprobe, arguments: args)
            guard result.isSuccess else { return nil }
            return parseMlmUuidFromFfprobeJson(result.stdout)
        } catch {
            return nil
        }
    }

    /// Parse the MLM_UUID from ffprobe JSON output of format_tags.
    /// Looks for a key matching "TXXX:MLM_UUID" in the tags dictionary.
    static func parseMlmUuidFromFfprobeJson(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = obj["format"] as? [String: Any],
              let tags = format["tags"] as? [String: String] else {
            return nil
        }
        // ffmpeg writes TXXX frames as "TXXX:MLM_UUID" → "value"
        if let value = tags["TXXX:MLM_UUID"] {
            let cleaned = value.replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    // MARK: - m4a/aac/mp4 (comment field)

    private static func readMlmUuidFromM4a(url: URL) async -> String? {
        // Try AVMetadataItem first — the comment field is a common metadata key.
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata {
            let isComment = (item.key as? String) == "comment"
                || item.commonKey?.rawValue == "comment"
            if isComment, let value = item.stringValue {
                return SyncService.parseMlmUuid(fromComment: value)
            }
        }
        // Fallback to ffprobe
        guard let ffprobe = ProcessRunner.findExecutable("ffprobe") else { return nil }
        let args = [
            "-v", "quiet",
            "-show_entries", "format_tags=comment",
            "-of", "csv=p=0",
            url.path,
        ]
        do {
            let result = try await ProcessRunner.run(ffprobe, arguments: args)
            guard result.isSuccess else { return nil }
            let comment = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comment.isEmpty else { return nil }
            return SyncService.parseMlmUuid(fromComment: comment)
        } catch {
            return nil
        }
    }
}
