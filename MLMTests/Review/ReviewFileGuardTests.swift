import Foundation
import GRDB
import Testing
@testable import MLM

/// F2: the recommendation must have a file (W3-REV fixes).
@Suite("ReviewFileGuardTests", .serialized)
@MainActor
struct ReviewFileGuardTests {
    private let flacMp3: [(format: String, bitrate: Int)] = [("flac", 1411), ("mp3", 320)]

    private func markMissing(_ env: ReviewEnv, _ id: Int64) async throws {
        try await env.db.write { db in
            try db.execute(sql: "UPDATE tracks SET file_missing_since = '2026-10-01T10:00:00Z' WHERE id = ?", arguments: [id])
        }
    }

    @Test func aMissingFileFlacLosesToARealAac() {
        var flac = Track(artist: "A", album: "B", title: "T", format: "flac", originalPath: "/x.flac")
        flac.id = 1
        flac.bitrate = 1411
        flac.organizedPath = "A/T.flac"
        flac.fileMissingSince = "2026-10-01T10:00:00Z"
        var aac = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: "/x.m4a")
        aac.id = 2
        aac.bitrate = 248
        aac.organizedPath = "A/T.m4a"
        #expect(DuplicateReviewRecommendation.recommendedTrack(in: [flac, aac])?.id == 2)
        #expect(DuplicateReviewRecommendation.recommendation(for: [flac, aac], keepBoth: false)?.trackId == 2)
    }

    @Test func theRecommendationIsRecomputedAtDisplayTime() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        #expect(env.model.duplicates.first?.recommendedID == group.ids[0], "the scan's FLAC while its file is there")
        try await markMissing(env, group.ids[0])
        await env.model.reload()
        #expect(env.model.duplicates.first?.recommendedID == group.ids[1], "the file went missing after the scan")
    }

    @Test func keepingAFilelessVersionOverARealOneIsRefused() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        try await markMissing(env, group.ids[0])
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        let plan = env.model.plan(keep: group.ids[0], in: item, action: .keepSelected)
        let applied = await env.model.apply([plan], actionName: "Keep Selected Version", undo: env.undo)
        #expect(!applied)
        #expect(env.status.message?.text == "Can’t keep “So U Kno” — its file is missing")
        #expect(env.undo.stepCount == 0)
        let hidden = try await env.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hidden == 0)
        await #expect(throws: ReviewDecisionError.self) {
            try await env.decisions.decide(plan.request)
        }
    }

    @Test func keepingTheOnlyFilelessVersionStillWorks() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        try await markMissing(env, group.ids[0])
        try await markMissing(env, group.ids[1])
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        let applied = await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        #expect(applied, "no other version has a file, so nothing is lost")
    }

    @Test func bulkSkipsGroupsWhoseRecommendedVersionHasNoFile() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "Alpha", versions: flacMp3)
        let beta = try await env.addGroup(title: "Beta", versions: flacMp3)
        await env.model.reload()
        let items = env.model.duplicates
        let alpha = try #require(items.first { $0.title == "Alpha" })
        // Beta's recommendation points at a version that lost its file after it was computed.
        try await markMissing(env, beta.ids[0])
        let fresh = try #require(items.first { $0.title == "Beta" })
        var members = fresh.members
        members[0].fileMissingSince = "2026-10-01T10:00:00Z"
        let stale = ReviewGroupItem(key: fresh.key, kind: fresh.kind, members: members, recommendedID: fresh.recommendedID,
                                    recommendsKeepAll: false, why: fresh.why, matchPercent: fresh.matchPercent, usedIn: [:])
        #expect(!ReviewModel.recommendedHasNoFile(alpha))
        #expect(ReviewModel.recommendedHasNoFile(stale))
        let plans = [env.model.plan(keepRecommendedIn: alpha), env.model.plan(keepRecommendedIn: stale)]
        let applied = await env.model.apply(plans, actionName: "Keep Recommended Versions", undo: env.undo)
        #expect(applied)
        #expect(env.status.message?.text.hasSuffix("1 group skipped — the recommended version has no file") == true)
        #expect(env.model.duplicates.map(\.title) == ["Beta"], "the skipped group stays pending")
    }

    @Test func trashModeLeavesAFileTheKeptVersionSharesAndSaysSo() async throws {
        let env = try ReviewEnv.make(existingFiles: ["/lib/Overmono/shared.flac"])
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        try await env.db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = 'Overmono/shared.flac' WHERE id IN (?, ?)",
                           arguments: [group.ids[0], group.ids[1]])
        }
        await env.model.reload()
        env.model.setUnkeptMode(.trash)
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keep: group.ids[0], in: item, action: .keepRecommended)],
                              actionName: "Keep Recommended Version", undo: env.undo)
        #expect(env.files.trashed.isEmpty, "the kept version's file is never trashed")
        #expect(env.status.message?.text == "Kept the FLAC version of “So U Kno” · 0 versions moved to the Trash · 1 skipped")
        let record = try #require(try await env.decisions.decisions()[group.key])
        #expect(record.consequences.trashSkipped == 1)
        #expect(record.consequences.trashed.isEmpty)
    }
}
