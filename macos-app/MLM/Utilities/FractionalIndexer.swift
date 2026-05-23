import Foundation

/// A Swift port of the base-62 fractional indexing logic used in the Rust backend.
/// This ensures consistent and deterministic position calculation between macOS and Tauri clients.
struct FractionalIndexer {
    static let alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    static let delimiter: Character = "|"
    
    /// Generates a fractional index position between left and right positions.
    ///
    /// Uses string-based lexicographic ordering for unlimited precision.
    /// Cases:
    /// - (nil, nil) -> "a0" (first position)
    /// - (Some(left), nil) -> append "|a0" to left (insert after)
    /// - (nil, Some(right)) -> "a0" if right > "a0", else compute midpoint before right
    /// - (Some(left), Some(right)) -> compute midpoint string between left and right
    static func positionBetween(left: String?, right: String?) -> String {
        switch (left, right) {
        case (nil, nil):
            return "a0"
            
        case (let leftPos?, nil):
            return incrementPositionString(leftPos)
            
        case (nil, let rightPos?):
            if rightPos > "a0" {
                return "a0"
            } else {
                return midpointPositionString("", rightPos)
            }
            
        case (let leftPos?, let rightPos?):
            return midpointPositionString(leftPos, rightPos)
        }
    }
    
    private static func incrementPositionString(_ pos: String) -> String {
        return "\(pos)\(delimiter)a0"
    }
    
    private static func midpointPositionString(_ left: String, _ right: String) -> String {
        let leftChars = Array(left)
        let rightChars = Array(right)
        let alphabetChars = Array(alphabet)
        
        var result = ""
        var i = 0
        
        while true {
            let leftChar = i < leftChars.count ? leftChars[i] : nil
            let rightChar = i < rightChars.count ? rightChars[i] : nil
            
            switch (leftChar, rightChar) {
            case let (l?, r?) where l == r:
                result.append(l)
                i += 1
                
            case let (l?, r?):
                let lIdx = alphabet.firstIndex(of: l).map { alphabet.distance(from: alphabet.startIndex, to: $0) } ?? 0
                let rIdx = alphabet.firstIndex(of: r).map { alphabet.distance(from: alphabet.startIndex, to: $0) } ?? 0
                
                if rIdx <= lIdx + 1 {
                    result.append(l)
                    result.append(delimiter)
                    let midIdx = alphabetChars.count / 2
                    result.append(alphabetChars[midIdx])
                    return result
                }
                
                let midIdx = (lIdx + rIdx) / 2
                result.append(alphabetChars[midIdx])
                return result
                
            case let (nil, r?):
                let rIdx = alphabet.firstIndex(of: r).map { alphabet.distance(from: alphabet.startIndex, to: $0) } ?? 0
                if rIdx > 0 {
                    let midIdx = rIdx / 2
                    result.append(alphabetChars[midIdx])
                } else {
                    if result.isEmpty {
                        return "\(delimiter)\(alphabetChars[0])"
                    } else {
                        result.append(delimiter)
                        result.append(alphabetChars[0])
                    }
                }
                return result
                
            case (let _?, nil):
                result.append(delimiter)
                result.append(alphabetChars[0])
                return result
                
            case (nil, nil):
                result.append(delimiter)
                result.append(alphabetChars[0])
                return result
            }
        }
    }
}
