import Testing
@testable import MLM

@Suite struct FractionalIndexerTests {
    @Test func testEmptyPlaylist() {
        let result = FractionalIndexer.positionBetween(left: nil, right: nil)
        #expect(result == "a0")
    }

    @Test func testInsertAtEnd() {
        let result = FractionalIndexer.positionBetween(left: "a0", right: nil)
        #expect(result == "a0|a0")
    }

    @Test func testInsertAtBeginningBeforeA0() {
        // Since right_pos ("a0") is not > "a0", it computes midpoint between "" and "a0"
        let result = FractionalIndexer.positionBetween(left: nil, right: "a0")
        #expect(result == "I")
    }

    @Test func testInsertAtBeginningAfterA0() {
        // Since right_pos ("b0") is > "a0", it returns "a0"
        let result = FractionalIndexer.positionBetween(left: nil, right: "b0")
        #expect(result == "a0")
    }

    @Test func testInsertBetweenAdjacent() {
        // "a0" and "a1" are adjacent in the last character, so we extend with delimiter
        let result = FractionalIndexer.positionBetween(left: "a0", right: "a1")
        #expect(result == "a0|V")
    }

    @Test func testInsertBetweenNonAdjacent() {
        // "a0" and "a2" are not adjacent. Midpoint between '0' (idx 0) and '2' (idx 2) is '1' (idx 1).
        let result = FractionalIndexer.positionBetween(left: "a0", right: "a2")
        #expect(result == "a1")
    }

    @Test func testInsertBetweenStringAndItsPrefixWithDelimiter() {
        // Left: "a0", Right: "a0|a0"
        let result = FractionalIndexer.positionBetween(left: "a0", right: "a0|a0")
        #expect(result == "a0|0")
    }
}
