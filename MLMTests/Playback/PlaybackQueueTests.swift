import Testing
@testable import MLM

@Suite
struct PlaybackQueueTests {

    // MARK: - Helpers

    private func makeTrack(id: Int64, title: String = "T") -> Track {
        var t = Track(
            artist: "Artist",
            album: "Album",
            title: title,
            format: "mp3",
            originalPath: "path/\(id).mp3"
        )
        t.id = id
        return t
    }

    // MARK: - Init

    @Test
    func init_empty_hasNoUpcoming() {
        let q = PlaybackQueue()
        #expect(q.upcoming.isEmpty)
        #expect(q.playNext.isEmpty)
        #expect(q.context.isEmpty)
    }

    // MARK: - advance

    @Test
    func advance_popsPlayNextFirst() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.replaceContext([b, c], cap: 100)
        let next = q.advance()
        #expect(next == a)
        #expect(q.playNext.isEmpty)
        #expect(q.context == [b, c])
    }

    @Test
    func advance_popsContextWhenPlayNextEmpty() {
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        var q = PlaybackQueue()
        q.replaceContext([b, c], cap: 100)
        let next = q.advance()
        #expect(next == b)
        #expect(q.context == [c])
    }

    @Test
    func advance_returnsNilWhenBothEmpty() {
        var q = PlaybackQueue()
        let next = q.advance()
        #expect(next == nil)
    }

    // MARK: - replaceContext

    @Test
    func replaceContext_capsAtLimit() {
        let tracks = (1...10).map { makeTrack(id: Int64($0), title: "T\($0)") }
        var q = PlaybackQueue()
        q.replaceContext(tracks, cap: 3)
        #expect(q.context.count == 3)
        #expect(q.context.map(\.id) == [1, 2, 3])
    }

    @Test
    func replaceContext_preservesPlayNext() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.replaceContext([b, c], cap: 100)
        #expect(q.playNext == [a])
        #expect(q.context == [b, c])
    }

    @Test
    func replaceContext_dedupesAgainstPlayNext() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.replaceContext([a, b], cap: 100) // a is in playNext, should be excluded from context
        #expect(q.context == [b])
    }

    // MARK: - insertPlayNext

    @Test
    func insertPlayNext_appendsToPlayNext() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        var q = PlaybackQueue()
        q.insertPlayNext([a, b])
        #expect(q.playNext == [a, b])
    }

    @Test
    func insertPlayNext_movesFromContext() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        var q = PlaybackQueue()
        q.replaceContext([a, b, c], cap: 100)
        q.insertPlayNext([c]) // move c from context to playNext
        #expect(q.playNext == [c])
        #expect(q.context == [a, b])
    }

    @Test
    func insertPlayNext_dedupesExistingPlayNext() {
        let a = makeTrack(id: 1, title: "A")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.insertPlayNext([a]) // duplicate
        #expect(q.playNext == [a])
    }

    @Test
    func insertPlayNext_emptyIsNoOp() {
        var q = PlaybackQueue()
        q.insertPlayNext([])
        #expect(q.playNext.isEmpty)
    }

    // MARK: - playFromUpcoming

    @Test
    func playFromUpcoming_slicesCorrectly() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        let d = makeTrack(id: 4, title: "D")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.replaceContext([b, c, d], cap: 100)
        // upcoming = [a, b, c, d]
        let result = q.playFromUpcoming(c)
        #expect(result == c)
        #expect(q.playNext.isEmpty)
        #expect(q.context == [d]) // only d remains after c
    }

    @Test
    func playFromUpcoming_notFound_returnsNil() {
        let a = makeTrack(id: 1, title: "A")
        let z = makeTrack(id: 99, title: "Z")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        let result = q.playFromUpcoming(z)
        #expect(result == nil)
    }

    // MARK: - upcoming

    @Test
    func upcoming_returnsPlayNextThenContext() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        let c = makeTrack(id: 3, title: "C")
        var q = PlaybackQueue()
        q.insertPlayNext([a])
        q.replaceContext([b, c], cap: 100)
        #expect(q.upcoming == [a, b, c])
    }

    // MARK: - pushToFront

    @Test
    func pushToFront_insertsAtContextHead() {
        let a = makeTrack(id: 1, title: "A")
        let b = makeTrack(id: 2, title: "B")
        var q = PlaybackQueue()
        q.replaceContext([b], cap: 100)
        q.pushToFront(a)
        #expect(q.context == [a, b])
    }

    // MARK: - backRestartThreshold

    @Test
    func backRestartThreshold_is3() {
        // UC-TB-09: Previous restarts after more than 3 s (was 7 s before W2-C).
        #expect(PlaybackQueue.backRestartThreshold == 3.0)
    }

    // MARK: - Equatable

    @Test
    func equatable_sameState_areEqual() {
        var q1 = PlaybackQueue()
        let a = makeTrack(id: 1, title: "A")
        q1.insertPlayNext([a])
        let q2 = q1
        #expect(q1 == q2)
    }

    /// W2-D: entries have their own identity — the same track queued separately is two
    /// different entries, so two such queues differ.
    @Test
    func equatable_sameTrackDifferentEntries_differ() {
        var q1 = PlaybackQueue()
        var q2 = PlaybackQueue()
        let a = makeTrack(id: 1, title: "A")
        q1.insertPlayNext([a])
        q2.insertPlayNext([a])
        #expect(q1.upcoming == q2.upcoming)
        #expect(q1 != q2)
    }
}
