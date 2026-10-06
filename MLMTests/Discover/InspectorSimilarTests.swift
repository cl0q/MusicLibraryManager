import Foundation
import Testing
@testable import MLM

/// W5-1a G26: Info ▸ Audio lists the nearest in-library matches from `SimilarModel`'s own query
/// (no network), and `Show All` opens Similar.
@Suite("InspectorSimilarTests")
@MainActor
struct InspectorSimilarTests {
    @Test func theNearestRowsAreTheLibraryMatchesInRankOrderWithTheirPercentage() async throws {
        let env = try await SimilarModelTests.make()
        let rows = await SimilarModel.nearest(to: env.seed, dependencies: env.model.dependencies)
        #expect(rows.map(\.track.id) == [env.near, env.far], "held and hidden tracks are never listed")
        #expect(rows[0].match > rows[1].match)
        #expect((0...100).contains(rows[0].match))
        #expect(env.log.started.isEmpty, "no source is asked from Info")
    }

    @Test func atMostFiveAreListed() async throws {
        let track = Track(artist: "A", album: "", title: "T", format: "m4a", originalPath: "/o/t.m4a")
        let many = (1...9).map { index -> (track: Track, score: Float) in
            var copy = track
            copy.id = Int64(index)
            return (copy, 1 - Float(index) / 20)
        }
        let dependencies = SimilarModel.Dependencies(
            fetchTrack: { _ in nil }, similarInLibrary: { _, limit in Array(many.prefix(limit + 4)) },
            isAnalysed: { _ in true }, analyse: { _ in }, swarm: FakeSwarm(),
            startDownload: { _, _, _ in }, pipelineStatus: { _ in nil }, placement: { _, _ in nil })
        let rows = await SimilarModel.nearest(to: 1, dependencies: dependencies)
        #expect(rows.count == SimilarModel.inspectorLimit)
        #expect(SimilarModel.inspectorLimit == 5)
        #expect(rows.map(\.track.id) == [1, 2, 3, 4, 5])
    }

    @Test func aTrackThatIsNotAnalysedHasNoRows() async throws {
        let env = try await SimilarModelTests.make(analysed: false)
        #expect(await SimilarModel.nearest(to: env.seed, dependencies: env.model.dependencies).isEmpty)
    }

    @Test func matchPercentIsClamped() {
        #expect(SimilarModel.matchPercent(1.4) == 100)
        #expect(SimilarModel.matchPercent(-1) == 0)
        #expect(SimilarModel.matchPercent(0.874) == 87)
    }

    @Test func infoOffersShowAllThatPushesSimilar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MLM/Views/Inspector/InspectorAudioTab.swift"), encoding: .utf8)
        #expect(text.contains("Button(\"Show All\")"))
        #expect(text.contains("navigation?.push(.similar(trackID: id))"))
        #expect(!text.contains("Can’t analyze") && !text.contains("\"Analyze"), "one spelling: analyse")
    }
}
