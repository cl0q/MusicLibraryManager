import Foundation

/// A Swift port of the base-62 fractional indexing logic used in the Rust backend.
/// This ensures consistent and deterministic position calculation between macOS and Tauri clients.
///
/// **Root fix (W3-PL):** the ported midpoint is wrong for some pairs — it can return its left
/// bound (`a0|V`, `a1`), a key below the left bound (`a0|a0`, `a1`) or, before a key that starts
/// with a digit, one above the right bound (`nil`, `000000000000`). `positionBetween` now checks
/// the port's answer and, only when it isn't strictly between the bounds, computes one that is
/// (`strictBetween`). Every answer the port got right stays byte-identical, so existing
/// positions and the Tauri client keep agreeing.
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
    ///
    /// The result is strictly between the bounds (byte order, as SQLite's `BINARY` collation
    /// sorts it) whenever `left < right`; for bounds that are not ordered the port's answer is
    /// returned unchanged.
    static func positionBetween(left: String?, right: String?) -> String {
        let ported = portedPositionBetween(left: left, right: right)
        // In order — and, at the open start, not a key nothing fits before (the port's `0`).
        if isStrictlyBetween(ported, left, right), left != nil || strictBetween(nil, ported) != nil {
            return ported
        }
        return strictBetween(left, right) ?? ported
    }

    /// `position` sorts after `left` and before `right` (nil bounds are open), byte order.
    static func isStrictlyBetween(_ position: String, _ left: String?, _ right: String?) -> Bool {
        let p = Array(position.utf8)
        if let left, !Array(left.utf8).lexicographicallyPrecedes(p) { return false }
        if let right, !p.lexicographicallyPrecedes(Array(right.utf8)) { return false }
        return true
    }

    /// `count` keys in ascending order, evenly spread over two (or more) base-62 digits after
    /// `a` — room before, between and after each for later inserts. Used to give rows an order
    /// once (a backfill) instead of chaining `positionBetween(left:right: nil)`, whose keys grow
    /// by three characters per row.
    static func evenlySpaced(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let digits = Array(alphabet)
        var width = 2
        var capacity = digits.count * digits.count
        while capacity <= count {
            width += 1
            capacity *= digits.count
        }
        let step = capacity / (count + 1)
        return (1...count).map { index in
            var value = index * step
            var key = [Character](repeating: digits[0], count: width)
            for slot in stride(from: width - 1, through: 0, by: -1) {
                key[slot] = digits[value % digits.count]
                value /= digits.count
            }
            return "a" + String(key)
        }
    }

    // MARK: - The ported midpoint (unchanged)

    private static func portedPositionBetween(left: String?, right: String?) -> String {
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

            case (_?, nil):
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

    // MARK: - A key that is always strictly between

    /// A key strictly between `left` and `right` in byte order (nil = open bound), built from
    /// the base-62 digits; nil when no such key exists (`left >= right`, or `right` is `0`,
    /// `00`, … with no left bound — nothing sorts between `""` and those).
    ///
    /// Walks both bounds byte by byte. Where a digit fits strictly between the two bytes it is
    /// taken and the key ends. Otherwise the left byte is copied (the key is then below the
    /// right bound, which stops bounding) — or, with the left bound used up, the smallest digit
    /// below the right byte, or the right byte itself while still on its prefix. A key never
    /// ends in `0` once the left bound is used up, so there is always room below it later.
    /// Open-ended sides take the neighbouring digit (`b` after `a…`, `U` before `V…`), so
    /// repeated appends or prepends grow by one character per 61 inserts.
    static func strictBetween(_ left: String?, _ right: String?) -> String? {
        let a = Array((left ?? "").utf8)
        var upper: [UInt8]? = right.map { Array($0.utf8) }
        if let upper, !a.lexicographicallyPrecedes(upper) { return nil }
        let digits = Array(alphabet.utf8)
        let zero = Int(digits[0])
        var key: [UInt8] = []
        var index = 0
        // Bounded by: the left bound while `key` equals its prefix; the right one while `upper`.
        var followsLeft = true
        while index < 4096 {
            let lo = followsLeft && index < a.count ? Int(a[index]) : -1
            let hi: Int
            if let upper {
                guard index < upper.count else { return nil }  // only when right is a prefix of key
                hi = Int(upper[index])
            } else {
                hi = 256
            }
            let fits = digits.map(Int.init).filter { d in
                d > lo && d < hi && !(lo == -1 && d == zero)
            }
            if !fits.isEmpty {
                let pick: Int
                if hi == 256, lo >= 0 {
                    pick = fits[0]                 // after the left bound: its next digit
                } else if lo == -1, hi < 256 {
                    pick = fits[fits.count - 1]    // before the right bound: its previous digit
                } else {
                    pick = fits[fits.count / 2]    // both ends open, or both bound: the middle
                }
                key.append(UInt8(pick))
                return String(decoding: key, as: UTF8.self)
            }
            if lo == hi {
                key.append(UInt8(lo))
            } else if lo == -1 {
                // The left bound is used up and no digit above `0` fits below the right byte.
                if zero < hi {
                    key.append(UInt8(zero))        // below the right bound from here on
                    upper = nil
                } else {
                    key.append(UInt8(hi))          // still on the right bound's prefix
                }
                followsLeft = false
            } else {
                // lo < hi with no digit between: copy the left byte; the right bound no longer
                // binds (the key is already below it).
                key.append(UInt8(lo))
                upper = nil
            }
            index += 1
        }
        return nil
    }
}
