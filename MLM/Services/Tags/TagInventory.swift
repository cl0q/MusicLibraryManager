import CryptoKit
import Foundation

// MARK: - Inventory

/// A file's **raw** tag structure, read by MLM's own read-only parsers (W2-E review B2) — not
/// ffprobe's view, which can't see data an ffmpeg remux would drop (Serato `GEOB`, `POPM`,
/// FLAC seek tables, MP4 freeform atoms…).
///
/// Every item is a key (`ID3:TIT2`, `ID3:TXXX:‹description›`, `VC:ARTIST`, `MP4:©nam`,
/// `FLAC:PICTURE`) and a content fingerprint (decoded text, or `sha256:` of binary content).
/// `refusal` names the first thing that isn't on the verified allow-list: such a file is
/// never rewritten.
struct TagInventory: Equatable, Sendable {
    struct Item: Hashable, Sendable, Comparable {
        let key: String
        let content: String

        static func < (lhs: Item, rhs: Item) -> Bool {
            (lhs.key, lhs.content) < (rhs.key, rhs.content)
        }
    }

    var items: [Item] = []
    /// Why the file's tag data can't be kept intact through a rewrite (plain words for
    /// `contains tag data MLM can’t preserve (‹refusal›)`); nil = everything is allow-listed.
    var refusal: String?
    /// Gapless playback information: MP3 Xing/LAME `xing:‹delay›/‹padding›`, `xing` (no LAME
    /// values), `none`; MP4 a digest of the edit lists (`elst:…`).
    var gapless = "none"
    /// MP3: ID3v2 major version (3, 4); nil = no ID3v2 tag.
    var id3Version: Int?
    /// MP3: the 128-byte ID3v1 tag's fields (`title`, `artist`, `album`, `year`, `comment`,
    /// `track`, `genre`); nil = none.
    var id3v1: [String: String]?

    /// The first value stored under `key` (decoded text), nil when absent.
    func value(_ key: String) -> String? {
        items.first { $0.key == key }?.content
    }

    mutating func refuse(_ reason: String) {
        if refusal == nil { refusal = reason }
    }

    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Byte sources

/// Random access to a file's bytes (the whole file is never read into memory).
protocol TagByteSource {
    var size: UInt64 { get }
    func read(_ offset: UInt64, _ count: Int) throws -> Data
}

struct DataByteSource: TagByteSource {
    let data: Data
    var size: UInt64 { UInt64(data.count) }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset <= size else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = min(start + max(count, 0), data.endIndex)
        return data.subdata(in: start..<end)
    }
}

final class FileByteSource: TagByteSource {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}

struct TagInventoryError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Allow-lists and field keys

extension TagFileFormat {
    /// The raw inventory key of an edited field.
    func rawKey(_ field: TrackTagField, id3Version: Int? = nil) -> String? {
        switch self {
        case .mp3:
            switch field {
            case .title: return "ID3:TIT2"
            case .artist: return "ID3:TPE1"
            case .album: return "ID3:TALB"
            case .albumArtist: return "ID3:TPE2"
            case .genre: return "ID3:TCON"
            case .year: return (id3Version ?? 3) == 4 ? "ID3:TDRC" : "ID3:TYER"
            case .bpm: return "ID3:TBPM"
            }
        case .flac:
            switch field {
            case .title: return "VC:TITLE"
            case .artist: return "VC:ARTIST"
            case .album: return "VC:ALBUM"
            case .albumArtist: return "VC:ALBUMARTIST"
            case .genre: return "VC:GENRE"
            case .year: return "VC:DATE"
            case .bpm: return "VC:BPM"
            }
        case .m4a:
            switch field {
            case .title: return "MP4:©nam"
            case .artist: return "MP4:©ART"
            case .album: return "MP4:©alb"
            case .albumArtist: return "MP4:aART"
            case .genre: return "MP4:©gen"
            case .year: return "MP4:©day"
            case .bpm: return nil
            }
        }
    }
}

/// What MLM has verified to come through an ffmpeg `-c copy` remux unchanged in value
/// (`TagInventoryTests` crafts each item byte by byte and round-trips it).
enum TagAllowList {
    /// ID3v2 frames kept by both ID3v2.3 and ID3v2.4 rewrites.
    static let id3Common: Set<String> = [
        "TIT2", "TPE1", "TALB", "TPE2", "TCON", "TBPM", "TRCK", "TPOS", "TCOM", "TKEY", "TCOP",
        "TPUB", "TENC", "TIT3", "TSRC", "TFLT", "TMED", "TLAN", "TOPE", "TSSE", "TXXX", "APIC", "PRIV",
    ]
    /// ID3v2.3 only (ffmpeg moves the v2.4 sort and grouping frames into TXXX on a v2.3 write).
    static let id3v23: Set<String> = id3Common.union(["TYER"])
    static let id3v24: Set<String> = id3Common.union(["TDRC", "TSOP", "TSOA", "TSOT", "TIT1"])
    /// Frames that may appear more than once (keyed further by description / owner / index).
    static let id3Repeatable: Set<String> = ["TXXX", "APIC", "PRIV"]

    /// MP4 `ilst` items kept by the `ipod` muxer.
    static let mp4Items: Set<String> = [
        "©nam", "©ART", "aART", "©wrt", "©alb", "©day", "©too", "©cmt", "©gen", "cprt", "©grp", "©lyr",
        "desc", "cpil", "trkn", "disk", "pgap", "covr",
    ]

    /// Vorbis comments: any single-occurrence key except `COMMENT` (ffmpeg rewrites it as
    /// `DESCRIPTION`, losing a `DESCRIPTION` already there). Keys are compared case-insensitively.
    static let vorbisRefused: Set<String> = ["COMMENT"]

    /// FLAC metadata blocks kept: STREAMINFO (0), PADDING (1, may change), VORBIS_COMMENT (4),
    /// PICTURE (6).
    static let flacBlocks: Set<UInt8> = [0, 1, 4, 6]

    /// Items describing the writing tool: allowed to change.
    static let volatileKeys: Set<String> = ["ID3:TSSE", "VC:ENCODER", "MP4:©too"]
}

// MARK: - Reader

enum TagInventoryReader {
    static func read(fileURL: URL, format: TagFileFormat) throws -> TagInventory {
        try read(FileByteSource(url: fileURL), format: format)
    }

    static func read(_ source: TagByteSource, format: TagFileFormat) throws -> TagInventory {
        switch format {
        case .mp3: try mp3(source)
        case .flac: try flac(source)
        case .m4a: try mp4(source)
        }
    }

    // MARK: MP3 (ID3v2, ID3v1, APEv2, Lyrics3, Xing/LAME)

    static func mp3(_ source: TagByteSource) throws -> TagInventory {
        var inventory = TagInventory()
        var audioStart: UInt64 = 0
        let head = try source.read(0, 10)
        if head.count == 10, head.prefix(3) == Data("ID3".utf8) {
            let version = Int(head[3])
            let flags = head[5]
            let size = UInt64(syncsafe(head, 6))
            audioStart = 10 + size + ((flags & 0x10) != 0 ? 10 : 0)
            inventory.id3Version = version
            if version != 3 && version != 4 {
                inventory.refuse("an ID3v2.\(version) tag")
            } else if flags != 0 {
                inventory.refuse("an ID3 tag with unsynchronisation or an extended header")
            } else {
                let body = try source.read(10, Int(size))
                try id3Frames(body, version: version, into: &inventory)
            }
        }
        // ID3v1, Lyrics3 and APEv2 at the end.
        var end = source.size
        if source.size >= 128 {
            let tail = try source.read(source.size - 128, 128)
            if tail.prefix(3) == Data("TAG".utf8) {
                end -= 128
                let v1 = id3v1(tail)
                inventory.id3v1 = v1
                if !(v1["comment"] ?? "").isEmpty || !(v1["track"] ?? "").isEmpty {
                    inventory.refuse("an ID3v1 comment or track number")
                }
            }
        }
        if end >= 9 {
            let marker = try source.read(end - 9, 9)
            if marker == Data("LYRICS200".utf8) || marker == Data("LYRICSEND".utf8) { inventory.refuse("a Lyrics3 tag") }
        }
        if end >= 32, try source.read(end - 32, 8) == Data("APETAGEX".utf8) { inventory.refuse("an APE tag") }
        if source.size >= 32, try source.read(source.size - 32, 8) == Data("APETAGEX".utf8) { inventory.refuse("an APE tag") }
        inventory.gapless = try xing(source, from: audioStart)
        return inventory
    }

    static func syncsafe(_ data: Data, _ offset: Int) -> Int {
        let b = data.startIndex + offset
        return Int(data[b] & 0x7f) << 21 | Int(data[b + 1] & 0x7f) << 14 | Int(data[b + 2] & 0x7f) << 7 | Int(data[b + 3] & 0x7f)
    }

    private static func bigEndian(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        var value = 0
        for index in 0..<count { value = value << 8 | Int(data[data.startIndex + offset + index]) }
        return value
    }

    private static func id3Frames(_ body: Data, version: Int, into inventory: inout TagInventory) throws {
        let allowed = version == 4 ? TagAllowList.id3v24 : TagAllowList.id3v23
        var offset = 0
        var seen: [String: Int] = [:]
        while offset + 10 <= body.count {
            let idData = body.subdata(in: body.startIndex + offset..<body.startIndex + offset + 4)
            if idData.allSatisfy({ $0 == 0 }) { break } // padding
            guard let id = String(data: idData, encoding: .ascii), id.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
                inventory.refuse("an ID3 tag MLM can’t read")
                return
            }
            let size = version == 4 ? syncsafe(body, offset + 4) : bigEndian(body, offset + 4, 4)
            let frameFlags = bigEndian(body, offset + 8, 2)
            guard size >= 0, offset + 10 + size <= body.count else {
                inventory.refuse("an ID3 tag MLM can’t read")
                return
            }
            let content = body.subdata(in: body.startIndex + offset + 10..<body.startIndex + offset + 10 + size)
            offset += 10 + size
            guard allowed.contains(id) else {
                inventory.refuse(describe(id3Frame: id, content: content))
                continue
            }
            if frameFlags != 0 { inventory.refuse("an ID3 frame with flags (\(id))"); continue }
            let item: TagInventory.Item
            switch id {
            case "TXXX":
                guard let parts = text(content, version: version, split: true), !parts.isEmpty else {
                    inventory.refuse("an ID3 frame MLM can’t read (TXXX)"); continue
                }
                if parts.count > 2 { inventory.refuse("multiple values in TXXX:\(parts[0])"); continue }
                item = .init(key: "ID3:TXXX:\(parts[0])", content: parts.count > 1 ? parts[1] : "")
            case "APIC":
                guard let picture = apic(content, version: version) else { inventory.refuse("an ID3 picture MLM can’t read"); continue }
                item = .init(key: "ID3:APIC", content: picture)
            case "PRIV":
                let owner = content.prefix { $0 != 0 }
                item = .init(key: "ID3:PRIV:\(String(decoding: owner, as: UTF8.self))", content: TagInventory.digest(content))
            default:
                guard let parts = text(content, version: version, split: true) else {
                    inventory.refuse("an ID3 frame MLM can’t read (\(id))"); continue
                }
                if parts.count != 1 { inventory.refuse("multiple values in \(id)"); continue }
                if id == "TCON", isNumericGenre(parts[0]) { inventory.refuse("a numeric genre (TCON)"); continue }
                item = .init(key: "ID3:\(id)", content: parts[0])
            }
            seen[item.key, default: 0] += 1
            if seen[item.key, default: 0] > 1, item.key != "ID3:APIC" {
                inventory.refuse("duplicate \(item.key.replacingOccurrences(of: "ID3:", with: "")) frames")
            }
            inventory.items.append(item)
        }
    }

    /// Plain words for a frame MLM can't keep.
    static func describe(id3Frame id: String, content: Data) -> String {
        switch id {
        case "GEOB":
            let lower = String(decoding: content, as: UTF8.self).lowercased()
            if lower.contains("serato") { return "Serato markers" }
            if lower.contains("traktor") { return "Traktor data" }
            return "GEOB"
        case "POPM": return "a rating (POPM)"
        case "UFID": return "a unique file identifier (UFID)"
        case "COMM": return "comments (COMM)"
        case "USLT": return "lyrics (USLT)"
        case "SYLT": return "synchronised lyrics (SYLT)"
        case "RVA2", "RVAD": return "volume adjustment (\(id))"
        default: return id.hasPrefix("W") ? "a web link (\(id))" : id
        }
    }

    static func isNumericGenre(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) { return true }
        return trimmed.hasPrefix("(") && trimmed.dropFirst().prefix { $0.isNumber }.count > 0
    }

    /// A text frame's strings (NUL-separated values; trailing terminator dropped).
    static func text(_ content: Data, version: Int, split: Bool) -> [String]? {
        guard let encoding = content.first else { return nil }
        let raw = content.dropFirst()
        let string: String?
        switch encoding {
        case 0: string = String(data: raw, encoding: .isoLatin1)
        case 1: string = String(data: raw, encoding: .utf16)
        case 2: string = String(data: raw, encoding: .utf16BigEndian)
        case 3: string = String(data: raw, encoding: .utf8)
        default: string = nil
        }
        guard var string else { return nil }
        while string.hasSuffix("\u{0}") { string.removeLast() }
        // A UTF-16 value list repeats the BOM per value.
        let parts = string.components(separatedBy: "\u{0}").map { $0.replacingOccurrences(of: "\u{FEFF}", with: "") }
        return split ? parts : [parts.joined(separator: "\u{0}")]
    }

    /// `mime|type|description|sha256` of an APIC frame.
    static func apic(_ content: Data, version: Int) -> String? {
        guard let encoding = content.first else { return nil }
        var index = content.startIndex + 1
        guard let mimeEnd = content[index...].firstIndex(of: 0) else { return nil }
        let mime = String(decoding: content[index..<mimeEnd], as: UTF8.self)
        index = mimeEnd + 1
        guard index < content.endIndex else { return nil }
        let type = content[index]
        index += 1
        // Description terminated by one NUL (Latin-1/UTF-8) or two (UTF-16).
        let wide = encoding == 1 || encoding == 2
        var end = index
        while end < content.endIndex {
            if wide {
                if end + 1 < content.endIndex, content[end] == 0, content[end + 1] == 0, (end - index) % 2 == 0 { break }
                end += 1
            } else {
                if content[end] == 0 { break }
                end += 1
            }
        }
        guard end < content.endIndex else { return nil }
        let descriptionData = content[index..<end]
        let description = text(Data([encoding]) + descriptionData, version: version, split: false)?.first ?? ""
        let data = content[(end + (wide ? 2 : 1))...]
        return "\(mime.lowercased())|\(type)|\(description)|\(TagInventory.digest(Data(data)))"
    }

    static func id3v1(_ tail: Data) -> [String: String] {
        func field(_ range: Range<Int>) -> String {
            let bytes = tail.subdata(in: tail.startIndex + range.lowerBound..<tail.startIndex + range.upperBound)
            return (String(data: bytes.prefix { $0 != 0 }, encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespaces)
        }
        var fields = ["title": field(3..<33), "artist": field(33..<63), "album": field(63..<93), "year": field(93..<97)]
        let b = tail.startIndex
        if tail[b + 125] == 0, tail[b + 126] != 0 {
            fields["comment"] = field(97..<125)
            fields["track"] = String(tail[b + 126])
        } else {
            fields["comment"] = field(97..<127)
            fields["track"] = ""
        }
        fields["genre"] = String(tail[b + 127])
        return fields
    }

    /// `xing:‹delay›/‹padding›` from the first frame's Xing/Info + LAME header; `xing` without
    /// LAME values; `none` without a Xing/Info frame.
    static func xing(_ source: TagByteSource, from start: UInt64) throws -> String {
        let window = try source.read(start, 4096)
        var index = window.startIndex
        while index + 1 < window.endIndex, !(window[index] == 0xff && window[index + 1] & 0xe0 == 0xe0) { index += 1 }
        guard index + 1 < window.endIndex else { return "none" }
        let frame = window[index...].prefix(400)
        for tag in ["Xing", "Info"] {
            guard let range = frame.range(of: Data(tag.utf8)) else { continue }
            var offset = range.upperBound
            guard offset + 4 <= frame.endIndex else { return "xing" }
            let flags = bigEndian(Data(frame[offset..<offset + 4]), 0, 4)
            offset += 4
            if flags & 1 != 0 { offset += 4 }
            if flags & 2 != 0 { offset += 4 }
            if flags & 4 != 0 { offset += 100 }
            if flags & 8 != 0 { offset += 4 }
            guard offset + 24 <= frame.endIndex else { return "xing" }
            let delayPadding = frame[(offset + 21)..<(offset + 24)].map { Int($0) }
            let delay = delayPadding[0] << 4 | delayPadding[1] >> 4
            let padding = (delayPadding[1] & 0x0f) << 8 | delayPadding[2]
            return "xing:\(delay)/\(padding)"
        }
        return "none"
    }

    // MARK: FLAC

    static func flac(_ source: TagByteSource) throws -> TagInventory {
        var inventory = TagInventory()
        guard try source.read(0, 4) == Data("fLaC".utf8) else {
            inventory.refuse(try source.read(0, 3) == Data("ID3".utf8) ? "an ID3 tag in front of the FLAC data" : "a FLAC file MLM can’t read")
            return inventory
        }
        var offset: UInt64 = 4
        var first = true
        var keys: [String: Int] = [:]
        while true {
            let header = try source.read(offset, 4)
            guard header.count == 4 else { inventory.refuse("a FLAC file MLM can’t read"); break }
            let last = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7f
            let length = bigEndian(header, 1, 3)
            let body = type == 1 ? Data() : try source.read(offset + 4, length)
            offset += 4 + UInt64(length)
            if first, type != 0 { inventory.refuse("a FLAC file MLM can’t read") }
            first = false
            guard TagAllowList.flacBlocks.contains(type) else {
                switch type {
                case 2: inventory.refuse("an APPLICATION block")
                case 3: inventory.refuse("a seek table")
                case 5: inventory.refuse("a cue sheet")
                default: inventory.refuse("FLAC metadata block \(type)")
                }
                if last { break } else { continue }
            }
            switch type {
            case 0:
                inventory.items.append(.init(key: "FLAC:STREAMINFO", content: TagInventory.digest(body)))
            case 4:
                guard let comments = vorbisComments(body) else { inventory.refuse("Vorbis comments MLM can’t read"); break }
                for (key, value) in comments {
                    let upper = key.uppercased()
                    keys[upper, default: 0] += 1
                    if keys[upper, default: 0] > 1 { inventory.refuse("duplicate \(upper) comments") }
                    if TagAllowList.vorbisRefused.contains(upper) { inventory.refuse("a \(upper) comment") }
                    inventory.items.append(.init(key: "VC:\(upper)", content: value))
                }
            case 6:
                guard let picture = flacPicture(body) else { inventory.refuse("a FLAC picture MLM can’t read"); break }
                inventory.items.append(.init(key: "FLAC:PICTURE", content: picture))
            default:
                break
            }
            if last { break }
        }
        return inventory
    }

    /// Key/value pairs of a VORBIS_COMMENT block (vendor string left out: it names the writer).
    static func vorbisComments(_ body: Data) -> [(String, String)]? {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= body.count else { return nil }
            let b = body.startIndex + offset
            offset += 4
            return Int(body[b]) | Int(body[b + 1]) << 8 | Int(body[b + 2]) << 16 | Int(body[b + 3]) << 24
        }
        guard let vendorLength = u32(), offset + vendorLength <= body.count else { return nil }
        offset += vendorLength
        guard let count = u32() else { return nil }
        var result: [(String, String)] = []
        for _ in 0..<count {
            guard let length = u32(), offset + length <= body.count else { return nil }
            let bytes = body.subdata(in: body.startIndex + offset..<body.startIndex + offset + length)
            offset += length
            guard let entry = String(data: bytes, encoding: .utf8), let equals = entry.firstIndex(of: "=") else { return nil }
            let key = String(entry[..<equals])
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7d && $0 != "=" }) else { return nil }
            result.append((key, String(entry[entry.index(after: equals)...])))
        }
        return result
    }

    /// `type|mime|description|sha256` of a PICTURE block.
    static func flacPicture(_ body: Data) -> String? {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= body.count else { return nil }
            defer { offset += 4 }
            return bigEndian(body, offset, 4)
        }
        func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= body.count else { return nil }
            defer { offset += count }
            return body.subdata(in: body.startIndex + offset..<body.startIndex + offset + count)
        }
        guard let type = u32(), let mimeLength = u32(), let mime = bytes(mimeLength),
              let descriptionLength = u32(), let description = bytes(descriptionLength),
              bytes(16) != nil, let dataLength = u32(), let data = bytes(dataLength) else { return nil }
        return "\(type)|\(String(decoding: mime, as: UTF8.self).lowercased())|\(String(decoding: description, as: UTF8.self))|\(TagInventory.digest(data))"
    }

    // MARK: MP4

    struct Atom {
        let type: String
        /// Offsets of the payload within the data it was read from.
        let payload: Range<Int>
    }

    /// Atom names are bytes (`©nam` starts with 0xA9).
    static func latin1(_ bytes: Data) -> String {
        String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    static func atoms(_ data: Data, in range: Range<Int>) -> [Atom]? {
        var result: [Atom] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = bigEndian(data, offset, 4)
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { return nil }
                size = bigEndian(data, offset + 8, 8)
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { return nil }
            let typeBytes = data.subdata(in: data.startIndex + offset + 4..<data.startIndex + offset + 8)
            result.append(Atom(type: latin1(typeBytes), payload: offset + header..<offset + size))
            offset += size
        }
        return offset == range.upperBound ? result : nil
    }

    static func mp4(_ source: TagByteSource) throws -> TagInventory {
        var inventory = TagInventory()
        var offset: UInt64 = 0
        var moov: Data?
        while offset + 8 <= source.size {
            let header = try source.read(offset, 16)
            guard header.count >= 8 else { break }
            var size = UInt64(bigEndian(header, 0, 4))
            var headerLength: UInt64 = 8
            if size == 1, header.count == 16 {
                size = UInt64(bigEndian(header, 8, 8))
                headerLength = 16
            } else if size == 0 {
                size = source.size - offset
            }
            guard size >= headerLength, offset + size <= source.size else { inventory.refuse("an MP4 file MLM can’t read"); return inventory }
            let type = latin1(header.subdata(in: header.startIndex + 4..<header.startIndex + 8))
            switch type {
            case "moov":
                guard size < 256 << 20 else { inventory.refuse("an MP4 movie header MLM can’t read"); return inventory }
                moov = try source.read(offset + headerLength, Int(size - headerLength))
            case "ftyp", "mdat", "free", "skip", "wide":
                break
            default:
                inventory.refuse("MP4 data MLM can’t preserve (\(type))")
            }
            offset += size
        }
        guard let moov, let children = atoms(moov, in: 0..<moov.count) else {
            inventory.refuse("an MP4 file MLM can’t read")
            return inventory
        }
        var editLists: [String] = []
        for child in children {
            switch child.type {
            case "mvhd", "iods", "free", "skip":
                break
            case "trak":
                guard let trak = atoms(moov, in: child.payload) else { inventory.refuse("an MP4 track MLM can’t read"); continue }
                // Gapless playback is the audio track's edit list (a cover track's doesn't matter).
                let isAudio = trak.contains { part in
                    guard part.type == "mdia", let mdia = atoms(moov, in: part.payload),
                          let hdlr = mdia.first(where: { $0.type == "hdlr" }), hdlr.payload.count >= 12 else { return false }
                    let start = moov.startIndex + hdlr.payload.lowerBound + 8
                    return latin1(moov.subdata(in: start..<start + 4)) == "soun"
                }
                for part in trak {
                    if part.type == "udta" { inventory.refuse("MP4 track user data") }
                    if isAudio, part.type == "edts", let edits = atoms(moov, in: part.payload) {
                        for edit in edits where edit.type == "elst" {
                            editLists.append(elstEntries(moov, edit.payload, movieTimescale: movieTimescale(moov, children)))
                        }
                    }
                }
            case "udta":
                guard let udta = atoms(moov, in: child.payload) else { inventory.refuse("MP4 user data MLM can’t read"); continue }
                for part in udta {
                    switch part.type {
                    case "meta": mp4Meta(moov, part.payload, into: &inventory)
                    case "free", "skip": break
                    case "chpl": inventory.refuse("chapters (chpl)")
                    default: inventory.refuse("MP4 user data (\(part.type))")
                    }
                }
            case "meta":
                inventory.refuse("MP4 metadata keys (mdta)")
            default:
                inventory.refuse("MP4 data MLM can’t preserve (\(child.type))")
            }
        }
        inventory.gapless = editLists.isEmpty ? "none" : "elst:" + editLists.joined(separator: ";")
        return inventory
    }

    /// `mvhd` timescale (units per second of edit-list segment durations).
    static func movieTimescale(_ moov: Data, _ children: [Atom]) -> Int {
        guard let mvhd = children.first(where: { $0.type == "mvhd" }), mvhd.payload.count >= 24 else { return 0 }
        let version = moov[moov.startIndex + mvhd.payload.lowerBound]
        return bigEndian(moov, mvhd.payload.lowerBound + (version == 1 ? 20 : 12), 4)
    }

    /// An edit list as `‹seconds›@‹media time›x‹rate›` entries: the same edit in a different
    /// movie timescale (ffmpeg picks one per remux) reads the same; a changed priming doesn't.
    static func elstEntries(_ moov: Data, _ payload: Range<Int>, movieTimescale: Int) -> String {
        guard payload.count >= 8 else { return "?" }
        let version = moov[moov.startIndex + payload.lowerBound]
        let count = bigEndian(moov, payload.lowerBound + 4, 4)
        let entrySize = version == 1 ? 20 : 12
        var offset = payload.lowerBound + 8
        var entries: [String] = []
        for _ in 0..<count where offset + entrySize <= payload.upperBound {
            let duration = bigEndian(moov, offset, version == 1 ? 8 : 4)
            var mediaTime = bigEndian(moov, offset + (version == 1 ? 8 : 4), version == 1 ? 8 : 4)
            if version == 0, mediaTime == 0xffff_ffff { mediaTime = -1 }
            let rate = bigEndian(moov, offset + (version == 1 ? 16 : 8), 4)
            let seconds = movieTimescale > 0 ? Double(duration) / Double(movieTimescale) : Double(duration)
            entries.append("\(String(format: "%.6f", seconds))@\(mediaTime)x\(rate)")
            offset += entrySize
        }
        return entries.joined(separator: ",")
    }

    private static func mp4Meta(_ data: Data, _ range: Range<Int>, into inventory: inout TagInventory) {
        // `meta` is a full box: 4 bytes of version and flags before the children.
        guard range.count >= 4, let children = atoms(data, in: range.lowerBound + 4..<range.upperBound) else {
            inventory.refuse("MP4 metadata MLM can’t read")
            return
        }
        var seen: Set<String> = []
        for child in children {
            switch child.type {
            case "hdlr", "free", "skip": continue
            case "ilst": break
            case "keys": inventory.refuse("MP4 metadata keys (mdta)"); continue
            default: inventory.refuse("MP4 metadata (\(child.type))"); continue
            }
            guard let items = atoms(data, in: child.payload) else { inventory.refuse("MP4 metadata MLM can’t read"); continue }
            for item in items {
                guard TagAllowList.mp4Items.contains(item.type) else {
                    inventory.refuse(describe(mp4Item: item, data: data))
                    continue
                }
                guard seen.insert(item.type).inserted else { inventory.refuse("duplicate \(item.type) items"); continue }
                guard let dataAtoms = atoms(data, in: item.payload), !dataAtoms.isEmpty,
                      dataAtoms.allSatisfy({ $0.type == "data" && $0.payload.count >= 8 }) else {
                    inventory.refuse("an MP4 item MLM can’t read (\(item.type))"); continue
                }
                if item.type != "covr", dataAtoms.count != 1 { inventory.refuse("multiple values in \(item.type)"); continue }
                for atom in dataAtoms {
                    let kind = bigEndian(data, atom.payload.lowerBound, 4) & 0x00ff_ffff
                    let payload = data.subdata(in: data.startIndex + atom.payload.lowerBound + 8..<data.startIndex + atom.payload.upperBound)
                    let content: String
                    if kind == 1, let text = String(data: payload, encoding: .utf8) {
                        content = text
                    } else if kind == 1 {
                        inventory.refuse("an MP4 item MLM can’t read (\(item.type))"); continue
                    } else {
                        content = "t\(kind):" + TagInventory.digest(payload)
                    }
                    inventory.items.append(.init(key: "MP4:\(item.type)", content: content))
                }
            }
        }
    }

    static func describe(mp4Item item: Atom, data: Data) -> String {
        guard item.type == "----" else {
            switch item.type {
            case "tmpo": return "BPM (tmpo)"
            case "rtng": return "a rating (rtng)"
            default: return item.type
            }
        }
        var mean = "", name = ""
        for part in atoms(data, in: item.payload) ?? [] where part.payload.count >= 4 {
            let text = String(decoding: data.subdata(in: data.startIndex + part.payload.lowerBound + 4..<data.startIndex + part.payload.upperBound), as: UTF8.self)
            if part.type == "mean" { mean = text }
            if part.type == "name" { name = text }
        }
        if mean.lowercased().contains("serato") || name.lowercased().contains("serato") { return "Serato markers" }
        if name == "iTunSMPB" { return "gapless information (iTunSMPB)" }
        return name.isEmpty ? "----" : "----:\(name)"
    }
}

// MARK: - Comparison

enum TagInventoryComparison {
    /// nil when `after` differs from `before` only in the edited keys (each now `expected`,
    /// nil = absent) and the volatile keys.
    static func problem(before: TagInventory, after: TagInventory, expected: [String: String?], editedV1: Set<String>) -> String? {
        if let refusal = after.refusal { return "the copy has tag data MLM can’t preserve (\(refusal))" }
        guard before.gapless == after.gapless else { return "gapless information \(before.gapless) → \(after.gapless)" }
        if before.id3Version != nil, before.id3Version != after.id3Version { return "ID3 version changed" }
        let edited = Set(expected.keys)
        let skip = edited.union(TagAllowList.volatileKeys)
        let kept = before.items.filter { !skip.contains($0.key) }.sorted()
        let now = after.items.filter { !skip.contains($0.key) }.sorted()
        guard kept == now else {
            let lost = Set(kept).subtracting(now).map(\.key).sorted()
            let added = Set(now).subtracting(kept).map(\.key).sorted()
            return "tag data changed (lost \(lost), added \(added))"
        }
        for (key, value) in expected {
            let values = after.items.filter { $0.key == key }.map(\.content)
            if let value {
                guard values == [value] else { return "\(key) reads back \(values), expected “\(value)”" }
            } else {
                guard values.isEmpty else { return "\(key) should be gone" }
            }
        }
        switch (before.id3v1, after.id3v1) {
        case (nil, nil): break
        case (let old?, let new?):
            for (name, value) in old where !editedV1.contains(name) && new[name] != value {
                return "ID3v1 \(name) changed"
            }
        default: return "the ID3v1 tag would be added or lost"
        }
        return nil
    }

    /// The ID3v1 fields an edit of `field` may change.
    static func v1Fields(_ field: TrackTagField) -> Set<String> {
        switch field {
        case .title: ["title"]
        case .artist: ["artist"]
        case .album: ["album"]
        case .year: ["year"]
        case .genre: ["genre"]
        case .albumArtist, .bpm: []
        }
    }
}
