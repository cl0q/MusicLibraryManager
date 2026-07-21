import Foundation
import GRDB
import Testing
@testable import MLM

struct OrganizedPathMigrationServiceTests {
    private struct Fixture {
        let base: URL
        let library: URL
        let artifacts: URL
        let manager: DatabaseManager
        let service: OrganizedPathMigrationService
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("organized-path-migration-tests-\(UUID().uuidString)", isDirectory: true)
        let library = base.appendingPathComponent("library", isDirectory: true)
        let artifacts = base.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: base.appendingPathComponent("library.sqlite3"))
        let service = OrganizedPathMigrationService(
            database: manager.pool,
            databasePath: manager.databasePath,
            libraryRoot: library,
            artifactsDirectory: artifacts
        )
        return Fixture(
            base: base, library: library, artifacts: artifacts,
            manager: manager, service: service
        )
    }

    private func insertTrack(
        _ fixture: Fixture,
        organizedPath: String,
        title: String = "Song"
    ) async throws -> Int64 {
        try await fixture.manager.pool.write { db in
            var track = Track(
                artist: "Artist", album: "Album", title: title, format: "m4a",
                originalPath: "https://example.invalid/\(UUID().uuidString)"
            )
            track.organizedPath = organizedPath
            try track.insert(db)
            return track.id!
        }
    }

    @discardableResult
    private func writeAudio(
        _ fixture: Fixture,
        relativePath: String,
        bytes: [UInt8] = [0x4d, 0x4c, 0x4d]
    ) throws -> URL {
        let url = fixture.library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
        return url
    }

    private func fetchTrack(_ fixture: Fixture, id: Int64) async throws -> Track? {
        try await fixture.manager.pool.read { db in
            try Track.fetchOne(db, key: id)
        }
    }

    @Test func duplicateBasenamesRemainGroupedAndUnresolved() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/shared.m4a")
        try writeAudio(fixture, relativePath: "00_Artists/shared.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/shared.m4a")

        let report = try await fixture.service.audit()
        let row = try #require(report.rows.first { $0.trackID == id })

        #expect(row.status == .unresolved)
        #expect(row.candidates.map(\.relativePath) == [
            "00_Artists/shared.m4a", "01_SoundCloud/shared.m4a"
        ])
        #expect(row.candidates.allSatisfy { $0.reasons == [.exactBasename] })
        #expect(report.eligibleCount == 0)
    }

    @Test func uniqueExactBasenameIsEligible() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/unique.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/unique.m4a")

        let report = try await fixture.service.audit()
        let row = try #require(report.rows.first { $0.trackID == id })

        #expect(row.status == .eligible)
        #expect(row.selectedReason == .exactBasename)
        #expect(row.selectedRelativePath == "01_SoundCloud/unique.m4a")
    }

    @Test func oneDiskBasenameClaimedByMultipleTracksRemainsUnresolved() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstID = try await insertTrack(fixture, organizedPath: "old-a/shared.m4a")
        let secondID = try await insertTrack(fixture, organizedPath: "old-b/shared.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/shared.m4a")

        let report = try await fixture.service.audit()
        let first = try #require(report.rows.first { $0.trackID == firstID })
        let second = try #require(report.rows.first { $0.trackID == secondID })

        #expect(first.status == .unresolved)
        #expect(second.status == .unresolved)
        #expect(report.eligibleCount == 0)
    }

    @Test func fileReferencedByValidRowCannotBeClaimedByStaleRow() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let validID = try await insertTrack(
            fixture,
            organizedPath: "01_SoundCloud/shared.m4a",
            title: "Valid"
        )
        let staleID = try await insertTrack(
            fixture,
            organizedPath: "old/shared.m4a",
            title: "Stale"
        )
        try writeAudio(fixture, relativePath: "01_SoundCloud/shared.m4a")

        let report = try await fixture.service.audit()
        let valid = try #require(report.rows.first { $0.trackID == validID })
        let stale = try #require(report.rows.first { $0.trackID == staleID })

        #expect(valid.status == .alreadyValid)
        #expect(stale.status == .unresolved)
        #expect(report.eligibleCount == 0)
    }

    @Test func existingInternalStagingPathMigratesOnlyToFinalLibraryFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(
            fixture,
            organizedPath: ".mlm_staging/transcoded/staged.m4a"
        )
        try writeAudio(fixture, relativePath: ".mlm_staging/transcoded/staged.m4a")
        try writeAudio(fixture, relativePath: "00_Artists/staged.m4a")

        let report = try await fixture.service.audit()
        let row = try #require(report.rows.first { $0.trackID == id })

        #expect(row.status == .eligible)
        #expect(row.selectedRelativePath == "00_Artists/staged.m4a")
        #expect(row.candidates.map(\.relativePath) == ["00_Artists/staged.m4a"])
    }

    @Test func uniqueTrackIDFilenameWinsOverDuplicateBasenames() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/shared.m4a")
        try writeAudio(fixture, relativePath: "legacy-a/shared.m4a")
        try writeAudio(fixture, relativePath: "legacy-b/shared.m4a")
        let deterministic = "00_Artists/Artist - Song [\(id)].m4a"
        try writeAudio(fixture, relativePath: deterministic)

        let report = try await fixture.service.audit()
        let row = try #require(report.rows.first { $0.trackID == id })

        #expect(row.candidates.count == 3)
        #expect(row.status == .eligible)
        #expect(row.selectedReason == .trackID)
        #expect(row.selectedRelativePath == deterministic)
    }

    @Test func numericSuffixWithoutMatchingTrackIdentityIsNotTrusted() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/no-match.m4a")
        try writeAudio(fixture, relativePath: "00_Artists/Different - Track [\(id)].m4a")

        let report = try await fixture.service.audit()
        let row = try #require(report.rows.first { $0.trackID == id })

        #expect(row.status == .unresolved)
        #expect(row.candidates.isEmpty)
    }

    @Test func deterministicTrackIDClaimWinsOverAnotherRowsBasenameClaim() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let ownerID = try await insertTrack(fixture, organizedPath: "old/owner.m4a")
        let deterministicName = "Artist - Song [\(ownerID)].m4a"
        let basenameClaimID = try await insertTrack(
            fixture,
            organizedPath: "old/\(deterministicName)",
            title: "Other"
        )
        let deterministicPath = "01_SoundCloud/\(deterministicName)"
        try writeAudio(fixture, relativePath: deterministicPath)

        let report = try await fixture.service.audit()
        let owner = try #require(report.rows.first { $0.trackID == ownerID })
        let basenameClaim = try #require(report.rows.first { $0.trackID == basenameClaimID })

        #expect(owner.status == .eligible)
        #expect(owner.selectedReason == .trackID)
        #expect(owner.selectedRelativePath == deterministicPath)
        #expect(basenameClaim.status == .unresolved)
    }

    @Test func auditDoesNotWriteDatabaseAudioOrRecoveryArtifacts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/read-only.m4a")
        let audio = try writeAudio(
            fixture, relativePath: "00_Artists/read-only.m4a", bytes: [1, 2, 3, 4, 5]
        )
        let beforeAudio = try Data(contentsOf: audio)

        _ = try await fixture.service.audit()

        let fetchedTrackOptional = try await fetchTrack(fixture, id: id)
        let fetchedTrack = try #require(fetchedTrackOptional)
        #expect(fetchedTrack.organizedPath == "old/read-only.m4a")
        #expect(try Data(contentsOf: audio) == beforeAudio)
        #expect(!FileManager.default.fileExists(atPath: fixture.artifacts.path))
    }

    @Test func applyUpdatesOnlyOrganizedPathAndCreatesRecoveryArtifacts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstID = try await insertTrack(
            fixture, organizedPath: "old/first.m4a", title: "First"
        )
        let secondID = try await insertTrack(
            fixture, organizedPath: "old/second.m4a", title: "Second"
        )
        let firstAudio = try writeAudio(
            fixture, relativePath: "00_Artists/first.m4a", bytes: [10, 11]
        )
        let secondAudio = try writeAudio(
            fixture, relativePath: "01_SoundCloud/second.m4a", bytes: [20, 21]
        )
        let fetchedFirstBeforeOptional = try await fetchTrack(fixture, id: firstID)
        let fetchedSecondBeforeOptional = try await fetchTrack(fixture, id: secondID)
        let fetchedFirstBefore = try #require(fetchedFirstBeforeOptional)
        let fetchedSecondBefore = try #require(fetchedSecondBeforeOptional)
        let report = try await fixture.service.audit()

        let result = try await fixture.service.apply(report)

        let fetchedFirstAfterOptional = try await fetchTrack(fixture, id: firstID)
        let fetchedSecondAfterOptional = try await fetchTrack(fixture, id: secondID)
        let fetchedFirstAfter = try #require(fetchedFirstAfterOptional)
        let fetchedSecondAfter = try #require(fetchedSecondAfterOptional)
        #expect(result.updatedCount == 2)
        #expect(fetchedFirstAfter.organizedPath == "00_Artists/first.m4a")
        #expect(fetchedSecondAfter.organizedPath == "01_SoundCloud/second.m4a")
        #expect(fetchedFirstAfter.originalPath == fetchedFirstBefore.originalPath)
        #expect(fetchedSecondAfter.originalPath == fetchedSecondBefore.originalPath)
        #expect(fetchedFirstAfter.downloadStatus == fetchedFirstBefore.downloadStatus)
        #expect(fetchedSecondAfter.downloadStatus == fetchedSecondBefore.downloadStatus)
        #expect(try Data(contentsOf: firstAudio) == Data([10, 11]))
        #expect(try Data(contentsOf: secondAudio) == Data([20, 21]))
        #expect(FileManager.default.fileExists(atPath: result.backupURL.path))
        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(!result.backupURL.path.hasPrefix(fixture.library.path + "/"))
        #expect(!result.manifestURL.path.hasPrefix(fixture.library.path + "/"))
        let backupDatabase = try DatabaseQueue(path: result.backupURL.path)
        let firstBackupPath = try backupDatabase.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT organized_path FROM tracks WHERE id = ?",
                arguments: [firstID]
            )
        }
        #expect(firstBackupPath == "old/first.m4a")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            OrganizedPathMigrationService.Manifest.self,
            from: Data(contentsOf: result.manifestURL)
        )
        #expect(manifest.status == .applied)
        #expect(manifest.changes.count == 2)
        #expect(manifest.auditRows.count == 2)
        #expect(manifest.auditRows.allSatisfy { !$0.candidates.isEmpty })
        #expect(manifest.changes.allSatisfy { $0.beforeOrganizedPath.hasPrefix("old/") })
    }

    @Test func applyRollsBackAllRowsWhenExpectedUpdateCountMismatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstID = try await insertTrack(
            fixture, organizedPath: "old/first-rollback.m4a", title: "First Rollback"
        )
        let secondID = try await insertTrack(
            fixture, organizedPath: "old/second-rollback.m4a", title: "Second Rollback"
        )
        try writeAudio(fixture, relativePath: "00_Artists/first-rollback.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/second-rollback.m4a")
        let report = try await fixture.service.audit()

        // Simulate a concurrent/mismatched row by making SQLite ignore the second update.
        // The service must detect changesCount == 0 and roll the first update back too.
        try await fixture.manager.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER block_second_path_update
                BEFORE UPDATE OF organized_path ON tracks
                WHEN OLD.id = \(secondID)
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """)
        }

        var didThrow = false
        do {
            _ = try await fixture.service.apply(report)
        } catch {
            didThrow = true
        }

        let first = try await fetchTrack(fixture, id: firstID)
        let second = try await fetchTrack(fixture, id: secondID)
        #expect(didThrow)
        #expect(first?.organizedPath == "old/first-rollback.m4a")
        #expect(second?.organizedPath == "old/second-rollback.m4a")
    }

    @Test func rollbackRestoresMostRecentManifestTransactionally() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let firstID = try await insertTrack(fixture, organizedPath: "old/one.m4a", title: "One")
        let secondID = try await insertTrack(fixture, organizedPath: "old/two.m4a", title: "Two")
        try writeAudio(fixture, relativePath: "00_Artists/one.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/two.m4a")
        let report = try await fixture.service.audit()
        let applied = try await fixture.service.apply(report)

        let rollback = try await fixture.service.rollbackMostRecent()

        #expect(rollback.restoredCount == 2)
        #expect(rollback.manifestFinalizationWarning == nil)
        let firstRestored = try await fetchTrack(fixture, id: firstID)
        let secondRestored = try await fetchTrack(fixture, id: secondID)
        #expect(FileManager.default.fileExists(atPath: rollback.rollbackBackupURL.path))
        let rollbackBackupDatabase = try DatabaseQueue(path: rollback.rollbackBackupURL.path)
        let firstPreRollbackPath = try rollbackBackupDatabase.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT organized_path FROM tracks WHERE id = ?",
                arguments: [firstID]
            )
        }
        #expect(firstPreRollbackPath == "00_Artists/one.m4a")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            OrganizedPathMigrationService.Manifest.self,
            from: Data(contentsOf: applied.manifestURL)
        )
        #expect(manifest.status == .rolledBack)
        #expect(manifest.rolledBackAt != nil)
    }

    @Test func rollbackRecoversPreparedManifestAfterCommittedDatabaseChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/interrupted.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/interrupted.m4a")
        let report = try await fixture.service.audit()
        let applied = try await fixture.service.apply(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(
            OrganizedPathMigrationService.Manifest.self,
            from: Data(contentsOf: applied.manifestURL)
        )
        manifest.status = .prepared
        manifest.appliedAt = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: applied.manifestURL, options: .atomic)

        let rollback = try await fixture.service.rollbackMostRecent()

        let restored = try await fetchTrack(fixture, id: id)
        #expect(rollback.restoredCount == 1)
        #expect(restored?.organizedPath == "old/interrupted.m4a")
    }

    @Test func rollbackIgnoresManifestFromDifferentLibraryRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let id = try await insertTrack(fixture, organizedPath: "old/root-bound.m4a")
        try writeAudio(fixture, relativePath: "01_SoundCloud/root-bound.m4a")
        let report = try await fixture.service.audit()
        _ = try await fixture.service.apply(report)

        let otherLibrary = fixture.base.appendingPathComponent("other-library", isDirectory: true)
        try FileManager.default.createDirectory(at: otherLibrary, withIntermediateDirectories: true)
        let otherService = OrganizedPathMigrationService(
            database: fixture.manager.pool,
            databasePath: fixture.manager.databasePath,
            libraryRoot: otherLibrary,
            artifactsDirectory: fixture.artifacts
        )

        var didReject = false
        do {
            _ = try await otherService.rollbackMostRecent()
        } catch OrganizedPathMigrationService.MigrationError.noAppliedManifest {
            didReject = true
        }

        let unchanged = try await fetchTrack(fixture, id: id)
        #expect(didReject)
        #expect(unchanged?.organizedPath == "01_SoundCloud/root-bound.m4a")
    }
}
