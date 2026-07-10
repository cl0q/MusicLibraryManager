import Foundation

// Copying the exact static cleaning and parsing rules from ReelsInboxView
struct OCRVerifier {
    static func cleanOcrText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "🎵", with: "")
        cleaned = cleaned.replacingOccurrences(of: "🎶", with: "")
        cleaned = cleaned.replacingOccurrences(of: "👤", with: "")
        cleaned = cleaned.replacingOccurrences(of: "▶️", with: "")
        
        let noiseSuffixes = [
            " (Original Audio)", " (Originalton)", " (Original Sound)", " (Original-Audio)",
            " Original Audio", " Originalton", " Original Sound", " Original-Audio"
        ]
        for suffix in noiseSuffixes {
            cleaned = cleaned.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        
        if cleaned.lowercased().hasPrefix("originalton von ") {
            cleaned = String(cleaned.dropFirst("originalton von ".count))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static func isInstagramUiNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        let noiseKeywords = [
            "gefällt mir", "kommentieren", "teilen", "beitrag", "instagram", "reels", 
            "folgen", "abonnieren", "aufrufe", "views", "vor 1 tag", "vor 2 tagen", 
            "originalton", "original audio", "original sound", "original-audio", 
            "tonspur", "soundtrack", "audio hinzufügen", "sound hinzufügen",
            "nachricht", "profil", "entdecken", "suche", "suchbegriff"
        ]
        for keyword in noiseKeywords {
            if lower == keyword || lower.contains(keyword) {
                return true
            }
        }
        
        if lower.hasPrefix("@") {
            return true
        }
        
        if lower.range(of: "^[0-9:\\s,.]+$", options: .regularExpression) != nil {
            return true
        }
        
        return false
    }
    
    static func findBestOcrCandidate(in texts: [String]) -> (artist: String, title: String)? {
        let delimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":"]
        var candidates: [(artist: String, title: String, score: Int)] = []
        
        for text in texts {
            let cleanedText = cleanOcrText(text)
            guard cleanedText.count >= 4 else { continue }
            if isInstagramUiNoise(cleanedText) { continue }
            
            var foundDelimiter = false
            for delimiter in delimiters {
                let parts = cleanedText.components(separatedBy: delimiter)
                if parts.count >= 2 {
                    let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !artist.isEmpty && !title.isEmpty && artist.count > 1 && title.count > 1 {
                        var score = 100
                        if cleanedText.lowercased().contains("original") {
                            score -= 20
                        }
                        candidates.append((artist: artist, title: title, score: score))
                        foundDelimiter = true
                        break
                    }
                }
            }
        }
        
        candidates.sort {
            if $0.score == $1.score {
                return ($0.artist.count + $0.title.count) > ($1.artist.count + $1.title.count)
            }
            return $0.score > $1.score
        }
        
        if let best = candidates.first {
            return (artist: best.artist, title: best.title)
        }
        return nil
    }
}

// Verification Test Suite
let testCases = [
    // Format: (Input recognized texts, Expected Cleaned Candidate or nil)
    (
        input: ["gefällt mir", "1.234", "@instagram_user", "🎵 Metallica - One (Originalton)", "vor 2 tagen"],
        expectedArtist: "Metallica",
        expectedTitle: "One"
    ),
    (
        input: ["🎶 Fred again.. - Jungle", "Profil anzeigen", "23.4K views"],
        expectedArtist: "Fred again..",
        expectedTitle: "Jungle"
    ),
    (
        input: ["Originalton von Daft Punk • Get Lucky", "originalton", "suche"],
        expectedArtist: "Daft Punk",
        expectedTitle: "Get Lucky"
    ),
    (
        input: ["👤 Travis Scott | FE!N (Original Audio)", "Teilen", "Kommentieren"],
        expectedArtist: "Travis Scott",
        expectedTitle: "FE!N"
    ),
    (
        input: ["Some random story text", "No delimiter here", "12:30"],
        expectedArtist: "",
        expectedTitle: ""
    )
]

print("==========================================================")
print(" 🔍 MLM OCR Rules & Heuristics Assessment Suite 🔍")
print("==========================================================\n")

var passedCount = 0
for (index, testCase) in testCases.enumerated() {
    print("Test Case \(index + 1):")
    print("  Inputs: \(testCase.input)")
    
    // Clean and check texts
    let cleanedTexts = testCase.input.map { OCRVerifier.cleanOcrText($0) }
    let filteredTexts = cleanedTexts.filter { !$0.isEmpty && !OCRVerifier.isInstagramUiNoise($0) }
    print("  Cleaned & Filtered: \(filteredTexts)")
    
    let result = OCRVerifier.findBestOcrCandidate(in: testCase.input)
    if let result = result {
        print("  Detected Candidate: Artist: \"\(result.artist)\", Title: \"\(result.title)\"")
        if result.artist == testCase.expectedArtist && result.title == testCase.expectedTitle {
            print("  🟢 PASSED\n")
            passedCount += 1
        } else {
            print("  🔴 FAILED (Expected Artist: \"\(testCase.expectedArtist)\", Title: \"\(testCase.expectedTitle)\")\n")
        }
    } else {
        print("  Detected Candidate: None")
        if testCase.expectedArtist.isEmpty && testCase.expectedTitle.isEmpty {
            print("  🟢 PASSED\n")
            passedCount += 1
        } else {
            print("  🔴 FAILED (Expected Artist: \"\(testCase.expectedArtist)\", Title: \"\(testCase.expectedTitle)\")\n")
        }
    }
}

print("==========================================================")
print(" Result: \(passedCount)/\(testCases.count) Tests Passed")
print("==========================================================")
if passedCount == testCases.count {
    exit(0)
} else {
    exit(1)
}
