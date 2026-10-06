import Testing
@testable import MLM

/// W3-PL root fix of `FractionalIndexer.positionBetween`: always strictly between ordered
/// bounds; every answer the port got right is unchanged (`FractionalIndexerTests` stays green).
@Suite struct FractionalIndexerRootFixTests {
    private func between(_ left: String?, _ right: String?) -> String {
        FractionalIndexer.positionBetween(left: left, right: right)
    }

    private func isOrdered(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    @Test func pairsThePortGotWrongAreNowStrictlyBetween() {
        let pairs: [(String?, String?)] = [
            ("a0|V", "a1"),            // the port returned its left bound
            ("a0|a0", "a1"),           // the port returned a key below its left bound
            (nil, "000000000001"),     // before a digit key: the port returned "|0" (above it)
            ("000000000001", "000000000002"),
            ("a0|a0|a0", "a0|a1"),
            ("Zz", "a"),
        ]
        for (left, right) in pairs {
            let key = between(left, right)
            #expect(FractionalIndexer.isStrictlyBetween(key, left, right), "\(left ?? "nil") < \(key) < \(right ?? "nil")")
        }
    }

    /// The port's `0` before `1` is in order but leaves nothing before it; another key is used.
    @Test func aKeyWithNoRoomBeforeItIsNeverHandedOut() {
        let key = between(nil, "1")
        #expect(key != "0")
        #expect(FractionalIndexer.isStrictlyBetween(key, nil, "1"))
        #expect(FractionalIndexer.strictBetween(nil, key) != nil)
        #expect(FractionalIndexer.strictBetween(nil, "000") == nil)
    }

    @Test func answersThePortGotRightAreUnchanged() {
        #expect(between(nil, nil) == "a0")
        #expect(between("a0", nil) == "b", "appends: the next digit (review B3)")
        #expect(between(nil, "a0") == "I")
        #expect(between(nil, "b0") == "a0")
        #expect(between("a0", "a1") == "a0|V")
        #expect(between("a0", "a2") == "a1")
        #expect(between("a0", "a0|a0") == "a0|0")
    }

    @Test func noKeyFitsBeforeZeroWithoutALeftBound() {
        #expect(FractionalIndexer.strictBetween(nil, "0") == nil)
        #expect(FractionalIndexer.strictBetween("b", "a") == nil)
        #expect(FractionalIndexer.strictBetween("a", "a") == nil)
        // Only bytes below `0` would fit between `a` and `a0`; keys are built from digits.
        #expect(FractionalIndexer.strictBetween("a", "a0") == nil)
    }

    @Test func repeatedInsertsAtTheFrontTheEndAndTheMiddleKeepTheOrder() {
        var keys = ["a0"]
        for round in 0..<600 {
            switch round % 3 {
            case 0: keys.insert(between(nil, keys.first), at: 0)
            case 1: keys.append(between(keys.last, nil))
            default:
                let index = keys.count / 2
                keys.insert(between(keys[index - 1], keys[index]), at: index)
            }
        }
        for (a, b) in zip(keys, keys.dropFirst()) {
            #expect(isOrdered(a, b), "\(a) < \(b)")
        }
        #expect(Set(keys).count == keys.count)
    }

    @Test func repeatedInsertsBeforeTheFirstKeyStayShort() {
        var first = "a0"
        for _ in 0..<200 {
            let key = between(nil, first)
            #expect(isOrdered(key, first))
            first = key
        }
        #expect(first.count < 12, "prepends grow by about one character per 61 inserts: \(first)")
    }

    @Test func randomOrderedPairsAlwaysGetAKeyBetween() {
        var generator = SystemRandomNumberGenerator()
        let characters = Array(FractionalIndexer.alphabet + "|")
        func randomKey() -> String {
            let length = Int.random(in: 1...6, using: &generator)
            return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
        }
        for _ in 0..<2000 {
            var left = randomKey()
            var right = randomKey()
            if left == right { continue }
            if !isOrdered(left, right) { swap(&left, &right) }
            // `right` = `left` + `0…`: no digit key fits (see noKeyFitsBeforeZero…).
            if FractionalIndexer.strictBetween(left, right) == nil {
                #expect(right.hasPrefix(left) && right.dropFirst(left.count).allSatisfy { $0 == "0" })
                continue
            }
            let key = between(left, right)
            #expect(FractionalIndexer.isStrictlyBetween(key, left, right), "\(left) < \(key) < \(right)")
        }
    }

    @Test func evenlySpacedKeysAreAscendingAndLeaveRoom() {
        for count in [1, 2, 28, 61, 500, 4000] {
            let keys = FractionalIndexer.evenlySpaced(count: count)
            #expect(keys.count == count)
            for (a, b) in zip(keys, keys.dropFirst()) {
                #expect(isOrdered(a, b))
                #expect(FractionalIndexer.isStrictlyBetween(between(a, b), a, b))
            }
            if let first = keys.first {
                #expect(FractionalIndexer.isStrictlyBetween(between(nil, first), nil, first))
            }
        }
        #expect(FractionalIndexer.evenlySpaced(count: 0).isEmpty)
    }

    @Test func theGuardedPlacementAgreesWithTheFixedIndexer() {
        #expect(PlaylistPlacement.strictlyBetween("a0|V", "a1") == between("a0|V", "a1"))
        #expect(FractionalIndexer.isStrictlyBetween(PlaylistPlacement.strictlyBetween(nil, "0001"), nil, "0001"))
    }
}
