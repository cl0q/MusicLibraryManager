import Foundation
@testable import MLM

/// Byte-level builders for tag fixtures **not** produced by ffmpeg's muxers (W2-E review B2):
/// raw ID3v2 frames, ID3v1, FLAC metadata blocks, MP4 atoms — injected into audio that ffmpeg
/// generated, or into bare containers for the pure parser tests.
enum TagFixtureBytes {
    // MARK: ID3

    static func syncsafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7f), UInt8((value >> 14) & 0x7f), UInt8((value >> 7) & 0x7f), UInt8(value & 0x7f)])
    }

    static func be32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    static func le32(_ value: Int) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }

    static func latin1(_ string: String) -> Data { string.data(using: .isoLatin1)! }

    /// A text frame body: encoding 0 (Latin-1), 1 (UTF-16 with BOM) or 3 (UTF-8).
    static func text(_ string: String, encoding: UInt8 = 0) -> Data {
        switch encoding {
        case 1: return Data([1]) + Data([0xff, 0xfe]) + string.data(using: .utf16LittleEndian)!
        case 3: return Data([3]) + Data(string.utf8)
        default: return Data([0]) + latin1(string)
        }
    }

    static func txxx(_ description: String, _ value: String) -> Data {
        Data([0]) + latin1(description) + Data([0]) + latin1(value)
    }

    static func apic(_ image: Data, type: UInt8 = 3, mime: String = "image/jpeg") -> Data {
        Data([0]) + latin1(mime) + Data([0, type, 0]) + image
    }

    static func geob(_ description: String) -> Data {
        Data([0]) + latin1("application/octet-stream") + Data([0, 0]) + latin1(description) + Data([0, 1, 1, 2, 3])
    }

    static func popm() -> Data { latin1("a@b.c") + Data([0, 0xff, 0, 0, 0, 5]) }
    static func ufid() -> Data { latin1("http://musicbrainz.org") + Data([0]) + latin1("abc-123") }
    static func comm(_ text: String) -> Data { Data([0]) + latin1("eng") + Data([0]) + latin1(text) }
    static func uslt(_ text: String) -> Data { Data([0]) + latin1("eng") + Data([0]) + latin1(text) }

    static func id3(version: UInt8, flags: UInt8 = 0, frames: [(String, Data)]) -> Data {
        var body = Data()
        for (id, content) in frames {
            body += Data(id.utf8)
            body += version == 4 ? syncsafe(content.count) : be32(content.count)
            body += Data([0, 0]) + content
        }
        return Data("ID3".utf8) + Data([version, 0, flags]) + syncsafe(body.count) + body
    }

    static func id3v1(title: String, artist: String, album: String, year: String, comment: String = "", track: UInt8 = 0, genre: UInt8 = 17) -> Data {
        func field(_ value: String, _ length: Int) -> Data {
            var data = latin1(value).prefix(length)
            data += Data(repeating: 0, count: length - data.count)
            return Data(data)
        }
        var tail = Data("TAG".utf8) + field(title, 30) + field(artist, 30) + field(album, 30) + field(year, 4)
        tail += track > 0 ? field(comment, 28) + Data([0, track]) : field(comment, 30)
        return tail + Data([genre])
    }

    /// Replace an MP3's leading ID3v2 tag (if any) with `tag`; drop a trailing ID3v1.
    static func retag(mp3 data: Data, with tag: Data, appending tail: Data = Data()) -> Data {
        var audio = data
        if audio.prefix(3) == Data("ID3".utf8) {
            let size = TagInventoryReader.syncsafe(audio, 6)
            audio = audio.subdata(in: audio.startIndex + 10 + size..<audio.endIndex)
        }
        if audio.count >= 128, audio.suffix(128).prefix(3) == Data("TAG".utf8) { audio = audio.dropLast(128) }
        return tag + audio + tail
    }

    /// A first MPEG frame with an `Info` header and LAME delay/padding — enough for the parser.
    static func infoFrame(delay: Int, padding: Int) -> Data {
        var frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(repeating: 0, count: 32)
        frame += Data("Info".utf8) + be32(0x0f) + be32(100) + be32(10_000) + Data(repeating: 0, count: 100) + be32(0)
        var lame = Data("LAME3.100".utf8) + Data(repeating: 0, count: 12)
        lame += Data([UInt8(delay >> 4), UInt8((delay & 0x0f) << 4 | padding >> 8), UInt8(padding & 0xff)])
        frame += lame + Data(repeating: 0, count: 200)
        return frame
    }

    // MARK: FLAC

    static func flacBlock(_ type: UInt8, _ body: Data, last: Bool = false) -> Data {
        Data([type | (last ? 0x80 : 0)]) + Data([UInt8((body.count >> 16) & 0xff), UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)]) + body
    }

    static func vorbisComments(_ comments: [String], vendor: String = "reference libFLAC 1.4.3") -> Data {
        var body = le32(vendor.utf8.count) + Data(vendor.utf8) + le32(comments.count)
        for comment in comments { body += le32(comment.utf8.count) + Data(comment.utf8) }
        return body
    }

    static func flacPicture(_ image: Data, type: Int = 3, mime: String = "image/png") -> Data {
        be32(type) + be32(mime.utf8.count) + Data(mime.utf8) + be32(0) + be32(64) + be32(64) + be32(24) + be32(0) + be32(image.count) + image
    }

    static let seekTable = Data(repeating: 0, count: 18)

    /// Split a FLAC file into its STREAMINFO body and its audio frames.
    static func flacParts(_ data: Data) -> (streamInfo: Data, frames: Data) {
        var offset = 4
        var streamInfo = Data()
        while true {
            let header = data[data.startIndex + offset]
            let length = Int(data[data.startIndex + offset + 1]) << 16 | Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
            if header & 0x7f == 0 { streamInfo = data.subdata(in: data.startIndex + offset + 4..<data.startIndex + offset + 4 + length) }
            offset += 4 + length
            if header & 0x80 != 0 { break }
        }
        return (streamInfo, data.subdata(in: data.startIndex + offset..<data.endIndex))
    }

    /// A FLAC with exactly `blocks` (type, body) after STREAMINFO.
    static func flac(streamInfo: Data, blocks: [(UInt8, Data)], frames: Data) -> Data {
        var data = Data("fLaC".utf8) + flacBlock(0, streamInfo, last: blocks.isEmpty)
        for (index, block) in blocks.enumerated() { data += flacBlock(block.0, block.1, last: index == blocks.count - 1) }
        return data + frames
    }

    // MARK: MP4

    static func box(_ type: String, _ payload: Data) -> Data {
        be32(8 + payload.count) + latin1(type) + payload
    }

    static func dataAtom(_ kind: Int, _ payload: Data) -> Data {
        box("data", be32(kind) + be32(0) + payload)
    }

    static func freeform(mean: String, name: String, kind: Int, payload: Data) -> Data {
        box("----", box("mean", be32(0) + Data(mean.utf8)) + box("name", be32(0) + Data(name.utf8)) + dataAtom(kind, payload))
    }

    /// Append `items` to the `ilst` of an M4A whose `moov` follows `mdat` (ffmpeg without
    /// `+faststart`), fixing the sizes of `moov`, `udta`, `meta` and `ilst`.
    static func injectIntoIlst(_ file: Data, items: Data) -> Data? {
        var data = file
        func child(_ type: String, in range: Range<Int>, skip: Int = 0) -> (start: Int, payload: Range<Int>)? {
            var offset = range.lowerBound + skip
            while offset + 8 <= range.upperBound {
                let size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                guard size >= 8 else { return nil }
                if String(decoding: data[offset + 4..<offset + 8], as: UTF8.self) == type { return (offset, offset + 8..<offset + size) }
                offset += size
            }
            return nil
        }
        guard let moov = child("moov", in: 0..<data.count),
              let udta = child("udta", in: moov.payload),
              let meta = child("meta", in: udta.payload),
              let ilst = child("ilst", in: meta.payload, skip: 4) else { return nil }
        for start in [moov.start, udta.start, meta.start, ilst.start] {
            let size = Int(data[start]) << 24 | Int(data[start + 1]) << 16 | Int(data[start + 2]) << 8 | Int(data[start + 3])
            data.replaceSubrange(start..<start + 4, with: be32(size + items.count))
        }
        data.insert(contentsOf: items, at: ilst.payload.upperBound)
        return data
    }

    /// A bare MP4 (no audio) for the parser: `ftyp`, `moov` with `mvhd` (timescale), an audio
    /// `trak` with an edit list, and `udta/meta/ilst` with `items`.
    static func bareMP4(items: Data, timescale: Int = 44_100, segment: Int = 132_300, mediaTime: Int = 1024, extraMoov: Data = Data()) -> Data {
        let mvhd = box("mvhd", Data([0, 0, 0, 0]) + be32(0) + be32(0) + be32(timescale) + be32(segment) + Data(repeating: 0, count: 80))
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + latin1("soun") + Data(repeating: 0, count: 13))
        let elst = box("elst", Data([0, 0, 0, 0]) + be32(1) + be32(segment) + be32(mediaTime) + be32(0x0001_0000))
        let trak = box("trak", box("edts", elst) + box("mdia", hdlr))
        let ilst = box("ilst", items)
        let meta = box("meta", Data([0, 0, 0, 0]) + box("hdlr", Data(repeating: 0, count: 25)) + ilst)
        let moov = box("moov", mvhd + trak + box("udta", meta) + extraMoov)
        return box("ftyp", latin1("M4A ") + be32(512)) + moov + box("mdat", Data(repeating: 0, count: 16))
    }
}
