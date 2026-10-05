import Foundation

/// The containers whose tags MLM rewrites without re-encoding audio, each verified by a
/// round trip in `TrackTagWriterTests` (ffmpeg `-c copy`, streams hashed before and after).
///
/// | Format | How | Fields |
/// |---|---|---|
/// | M4A (AAC, ALAC) | ffmpeg, `ipod` muxer, `-c copy`, `+faststart`; `mp4` muxer once if `ipod` refuses (exit 234) | all but BPM — ffmpeg can't write `tmpo` |
/// | MP3 | ffmpeg, `mp3` muxer, `-c copy`, the file's ID3v2 version (2.3/2.4), ID3v1 kept if present | all |
/// | FLAC | ffmpeg, `flac` muxer, `-c copy` | all |
///
/// Everything else (WAV, AIFF, OGG/Opus, raw AAC, …) is skipped with a reason: those
/// containers either can't hold every field (WAV INFO has no album artist) or ffmpeg can't
/// carry their cover art (Vorbis `METADATA_BLOCK_PICTURE`) through a copy — the database
/// stays the truth.
enum TagFileFormat: String, Sendable, CaseIterable {
    case m4a
    case mp3
    case flac

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "m4a": self = .m4a
        case "mp3": self = .mp3
        case "flac": self = .flac
        default: return nil
        }
    }

    init?(fileURL: URL) {
        self.init(pathExtension: fileURL.pathExtension)
    }

    /// Name for a file's format in a sentence: `WAV isn’t supported`.
    static func displayName(pathExtension: String) -> String {
        let ext = pathExtension.lowercased()
        switch ext {
        case "": return "This file type"
        case "aif", "aiff": return "AIFF"
        case "ogg", "oga": return "Ogg"
        case "opus": return "Opus"
        default: return ext.uppercased()
        }
    }

    var displayName: String { Self.displayName(pathExtension: rawValue) }

    /// Fields ffmpeg can write into this container (and read back to verify).
    var writableFields: Set<TrackTagField> {
        switch self {
        case .m4a: Set(TrackTagField.allCases).subtracting([.bpm])
        case .mp3, .flac: Set(TrackTagField.allCases)
        }
    }

    /// ffmpeg's metadata key for `field` in this container — also the key ffprobe reads back
    /// (compared case-insensitively).
    func metadataKey(_ field: TrackTagField) -> String? {
        guard writableFields.contains(field) else { return nil }
        switch field {
        case .title: return "title"
        case .artist: return "artist"
        case .album: return "album"
        case .albumArtist: return "album_artist"
        case .genre: return "genre"
        case .year: return "date"
        case .bpm: return self == .mp3 ? "TBPM" : "BPM"
        }
    }

    /// ffmpeg muxer.
    var muxer: String {
        switch self {
        case .m4a: "ipod"
        case .mp3: "mp3"
        case .flac: "flac"
        }
    }
}
