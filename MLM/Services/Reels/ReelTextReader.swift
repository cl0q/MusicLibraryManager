import CoreGraphics
import Foundation
import Vision

// MARK: - Text found in a video (V-REELS.E18, CM-REELS-TEXTPILL)

/// An `Artist – Title` shaped line read from a still, with the still it came from.
struct ReelTextCandidate: Hashable, Identifiable, Sendable {
    let artist: String
    let title: String
    let score: Int
    /// The offset of the first still it appeared in.
    var stillOffset: TimeInterval?

    var id: String { "\(artist.lowercased())|\(title.lowercased())" }
}

/// The text rules of today's code, moved out of the view unchanged: cleaning, the interface-noise
/// filter and the `Artist – Title` candidate search (German interface words stay — they are
/// what Instagram shows, not UI copy of MLM).
enum ReelTextParsing {
    /// Emoji markers and `Original Audio` suffixes removed.
    static func clean(_ text: String) -> String {
        var cleaned = text
        for marker in ["\u{1F3B5}", "\u{1F3B6}", "\u{1F464}", "\u{25B6}\u{FE0F}"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        let noiseSuffixes = [
            " (Original Audio)", " (Originalton)", " (Original Sound)", " (Original-Audio)",
            " Original Audio", " Originalton", " Original Sound", " Original-Audio",
        ]
        for suffix in noiseSuffixes {
            cleaned = cleaned.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        if cleaned.lowercased().hasPrefix("originalton von ") {
            cleaned = String(cleaned.dropFirst("originalton von ".count))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Instagram's own interface text, timestamps and handles.
    static func isInterfaceNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        let noiseKeywords = [
            "gefällt mir", "kommentieren", "teilen", "beitrag", "instagram", "reels",
            "folgen", "abonnieren", "aufrufe", "views", "vor 1 tag", "vor 2 tagen",
            "originalton", "original audio", "original sound", "original-audio",
            "tonspur", "soundtrack", "audio hinzufügen", "sound hinzufügen",
            "nachricht", "profil", "entdecken", "suche", "suchbegriff",
        ]
        for keyword in noiseKeywords where lower == keyword || lower.contains(keyword) {
            return true
        }
        if lower.hasPrefix("@") { return true }
        if lower.range(of: "^[0-9:\\s,.]+$", options: .regularExpression) != nil { return true }
        return false
    }

    static let candidateDelimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":"]

    /// Every `Artist – Title` shaped line, best first: score, then length. Moved verbatim from
    /// `findAllOcrCandidates`.
    static func candidates(in texts: [String]) -> [ReelTextCandidate] {
        var found: [(artist: String, title: String, score: Int)] = []
        var seen = Set<String>()
        for text in texts {
            let cleanedText = clean(text)
            guard cleanedText.count >= 4 else { continue }
            if isInterfaceNoise(cleanedText) { continue }
            for delimiter in candidateDelimiters {
                let parts = cleanedText.components(separatedBy: delimiter)
                if parts.count >= 2 {
                    let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !artist.isEmpty && !title.isEmpty && artist.count > 1 && title.count > 1 {
                        let key = "\(artist.lowercased()) - \(title.lowercased())"
                        if !seen.contains(key) {
                            seen.insert(key)
                            var score = 100
                            if cleanedText.lowercased().contains("original") { score -= 20 }
                            found.append((artist: artist, title: title, score: score))
                            break
                        }
                    }
                }
            }
        }
        found.sort {
            if $0.score == $1.score {
                return ($0.artist.count + $0.title.count) > ($1.artist.count + $1.title.count)
            }
            return $0.score > $1.score
        }
        return found.map { ReelTextCandidate(artist: $0.artist, title: $0.title, score: $0.score) }
    }

    /// The fragments worth showing: cleaned, longer than one character, no interface noise,
    /// longest first (as today).
    static func fragments(from frameTexts: [[String]]) -> [String] {
        var unique = Set<String>()
        for texts in frameTexts {
            for text in texts {
                let cleaned = clean(text)
                if cleaned.count > 1 && !isInterfaceNoise(cleaned) { unique.insert(cleaned) }
            }
        }
        return unique.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }
}

/// An image that crosses actors (`CGImage` is immutable).
struct ReelImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Reads the text of one still.
protocol ReelTextReading: Sendable {
    func read(_ image: ReelImage) async -> [String]
}

/// Vision text recognition (`VNRecognizeTextRequest`), with today's prominence filter and the
/// stacked-lines merger (an artist above a title becomes `Artist - Title`).
struct VisionReelTextReader: ReelTextReading {
    func read(_ image: ReelImage) async -> [String] {
        let cgImage = image.cgImage
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.strings(from: observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.shared.error("Text reading failed: \(error.localizedDescription)", source: "Reels")
                continuation.resume(returning: [])
            }
        }
    }

    private struct Block {
        let text: String
        let box: CGRect
    }

    private static func strings(from observations: [VNRecognizedTextObservation]) -> [String] {
        var blocks: [Block] = []
        for observation in observations {
            guard let primary = observation.topCandidates(3).first?.string else { continue }
            let size = observation.boundingBox.size
            // Only big text blocks that stand out; tiny watermarks, timelines and interface details go.
            let isProminent = (size.height >= 0.02) || (size.height >= 0.016 && size.width >= 0.08)
            if isProminent { blocks.append(Block(text: primary, box: observation.boundingBox)) }
        }
        var results = Set(blocks.map(\.text))
        for i in 0..<blocks.count {
            for j in 0..<blocks.count where i != j {
                let a = blocks[i]
                let b = blocks[j]
                let yDistance = a.box.origin.y - b.box.origin.y
                guard yDistance > 0.005 && yDistance < 0.08 else { continue }
                let centerDistance = abs((a.box.origin.x + a.box.size.width / 2) - (b.box.origin.x + b.box.size.width / 2))
                let overlaps = !(a.box.maxX < b.box.minX || b.box.maxX < a.box.minX)
                if centerDistance < 0.15 || overlaps {
                    results.insert("\(a.text) - \(b.text)")
                    results.insert("\(b.text) - \(a.text)")
                }
            }
        }
        return Array(results)
    }
}
