import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-PL review B1–B3: insertion *sequences* (not single pairs) from the start states real
/// libraries have — legacy `left|a0` chains, `%012d` import keys, v45 backfill keys — with the
/// writers' rule: `FractionalIndexer.key(between:and:)`, and when it returns nil, renumber the
/// list evenly and try again (never an out-of-order key). After every step the keys are in
/// strict order without duplicates; SQLite's `ORDER BY position` agrees with the list.
@Suite struct FractionalIndexerSequenceTests {
    /// Deterministic generator (SplitMix64) so a failure can be replayed.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func isStrictlyAscending(_ keys: [String]) -> Bool {
        zip(keys, keys.dropFirst()).allSatisfy { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private static func legacyChain(_ count: Int) -> [String] {
        var keys: [String] = []
        var last: String?
        for _ in 0..<count {
            let key = last.map { "\($0)|a0" } ?? "a0"   // what the port's appends wrote
            keys.append(key)
            last = key
        }
        return keys
    }

    private static func importKeys(_ count: Int) -> [String] {
        (0..<count).map { String(format: "%012d", $0) }
    }

    /// Insert at `index` with the writers' rule; returns whether a renumbering was needed.
    @discardableResult
    private static func insert(into keys: inout [String], at index: Int) -> Bool {
        let left = index > 0 ? keys[index - 1] : nil
        let right = index < keys.count ? keys[index] : nil
        if let key = FractionalIndexer.key(between: left, and: right) {
            keys.insert(key, at: index)
            return false
        }
        keys = FractionalIndexer.evenlySpaced(count: keys.count)
        let l = index > 0 ? keys[index - 1] : nil
        let r = index < keys.count ? keys[index] : nil
        guard let key = FractionalIndexer.key(between: l, and: r) else {
            Issue.record("no key even after renumbering at \(index)")
            return true
        }
        keys.insert(key, at: index)
        return true
    }

    private static func sqliteOrder(_ queue: DatabaseQueue, _ keys: [String]) throws -> [String] {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM k")
            for (index, key) in keys.enumerated() {
                try db.execute(sql: "INSERT INTO k (id, position) VALUES (?, ?)", arguments: [index, key])
            }
            return try String.fetchAll(db, sql: "SELECT position FROM k ORDER BY position")
        }
    }

    @Test func randomSequencesFromEveryStartStateStayInStrictOrder() throws {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: "CREATE TABLE k (id INTEGER PRIMARY KEY, position TEXT NOT NULL)") }
        var generator = SeededGenerator(state: 0x5EED_0042)
        let starts: [[String]] = [Self.legacyChain(12), Self.importKeys(30), FractionalIndexer.evenlySpaced(count: 30), []]
        for sequence in 0..<3000 {
            var keys = starts[sequence % starts.count]
            for _ in 0..<200 {
                // Front, end, second place and random spots — the drops that broke before.
                let choice = Int.random(in: 0..<10, using: &generator)
                let index: Int
                switch choice {
                case 0: index = 0
                case 1: index = keys.count
                case 2, 3: index = min(1, keys.count)
                default: index = Int.random(in: 0...keys.count, using: &generator)
                }
                Self.insert(into: &keys, at: index)
            }
            #expect(Self.isStrictlyAscending(keys), "sequence \(sequence)")
            #expect(Set(keys).count == keys.count, "sequence \(sequence): duplicate keys")
            if sequence % 10 == 0 {
                #expect(try Self.sqliteOrder(queue, keys) == keys, "sequence \(sequence): SQLite disagrees")
            }
        }
    }

    @Test func twoThousandInsertsAtOneSpotNeverBreakTheOrder() throws {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: "CREATE TABLE k (id INTEGER PRIMARY KEY, position TEXT NOT NULL)") }
        for start in [Self.importKeys(10), Self.legacyChain(10), FractionalIndexer.evenlySpaced(count: 10)] {
            for spot in [0, 1, 9] {
                var keys = start
                for _ in 0..<2000 { Self.insert(into: &keys, at: spot) }
                #expect(Self.isStrictlyAscending(keys))
                #expect(Set(keys).count == keys.count)
                #expect(try Self.sqliteOrder(queue, keys) == keys)
            }
        }
    }

    /// B2: nothing fits before an all-zero key — nil, never an out-of-order fallback.
    @Test func boundsWithoutRoomReturnNil() {
        #expect(FractionalIndexer.key(between: nil, and: "000000000000") == nil)
        #expect(FractionalIndexer.key(between: "a", and: "a000") == nil)
        #expect(FractionalIndexer.key(between: "b", and: "a") == nil)
        let next = FractionalIndexer.key(between: "000000000000", and: "000000000001")
        #expect(next.map { FractionalIndexer.isStrictlyBetween($0, "000000000000", "000000000001") } == true)
        #expect(FractionalIndexer.key(between: nil, and: nil) == "a0")
    }

    /// B1: the port's `X0` between `X` and `X1…` left no room — it is no longer handed out.
    @Test func thePortsDeadEndBetweenAKeyAndItsExtensionIsNotUsed() {
        let left = "a0"
        let right = "a01"
        let key = FractionalIndexer.key(between: left, and: right)
        #expect(key != nil)
        if let key {
            #expect(FractionalIndexer.isStrictlyBetween(key, left, right))
            #expect(FractionalIndexer.key(between: left, and: key) != nil, "room before the new key")
            #expect(FractionalIndexer.key(between: key, and: right) != nil, "room after the new key")
        }
    }

    /// B3: no length cap — keys over 4 KB still get a key between.
    @Test func keysOverFourKilobytesStillWork() {
        let long = Self.legacyChain(1500).last!   // ~4.5 KB
        #expect(long.utf8.count > 4096)
        let after = FractionalIndexer.key(between: long, and: nil)
        #expect(after.map { FractionalIndexer.isStrictlyBetween($0, long, nil) } == true)
        let before = FractionalIndexer.key(between: "a0", and: long)
        #expect(before.map { FractionalIndexer.isStrictlyBetween($0, "a0", long) } == true)
    }

    /// B3: appends grow by about one character per 61 rows, not three per row.
    @Test func appendsStayShort() {
        var keys: [String] = []
        for _ in 0..<2000 { Self.insert(into: &keys, at: keys.count) }
        #expect((keys.last?.utf8.count ?? 0) < 60)
        #expect(Self.isStrictlyAscending(keys))
    }

    /// The randomized generator covers 12-character and long keys too.
    @Test func randomPairsIncludingLongKeysGetAKeyOrNil() {
        var generator = SeededGenerator(state: 0xFEED)
        let characters = Array(FractionalIndexer.alphabet + "|")
        func randomKey() -> String {
            let length = [1, 3, 12, 40, 300].randomElement(using: &generator)!
            return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
        }
        for _ in 0..<3000 {
            var left = randomKey()
            var right = Bool.random(using: &generator) ? left + randomKey() : randomKey()
            if left == right { continue }
            if !Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8)) { swap(&left, &right) }
            if let key = FractionalIndexer.key(between: left, and: right) {
                #expect(FractionalIndexer.isStrictlyBetween(key, left, right), "\(left) < \(key) < \(right)")
            } else {
                #expect(right.hasPrefix(left) && right.dropFirst(left.count).allSatisfy { $0 == "0" })
            }
        }
    }
}
