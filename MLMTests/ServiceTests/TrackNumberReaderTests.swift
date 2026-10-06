import Foundation
import GRDB
import Testing
@testable import MLM

/// `Read Track Numbers` (W4-1): the tag parsing, the reader with a fake extractor on temporary
/// files, the import path's join row, the menu wiring.
@Suite("TrackNumberReaderTests")
struct TrackNumberReaderTests {
    // MARK: Tag parsing

    @Test func parsesTheFormsATagWrites() {
        #expect(MetadataExtractor.parseTagNumber("3") == 3)
        #expect(MetadataExtractor.parseTagNumber("3/12") == 3)
        #expect(MetadataExtractor.parseTagNumber(" 03 ") == 3)
        #expect(MetadataExtractor.parseTagNumber("2/2") == 2)
        #expect(MetadataExtractor.parseTagNumber("/12") == nil)
        #expect(MetadataExtractor.parseTagNumber("abc") == nil)
        #expect(MetadataExtractor.parseTagNumber("0") == nil)
        #expect(MetadataExtractor.parseTagNumber("") == nil)
        // iTunes `trkn`: 0, 0, track (16 bit), total (16 bit), 0, 0.
        #expect(MetadataExtractor.parseTagNumber(atom: Data([0, 0, 0, 7, 0, 12, 0, 0])) == 7)
        #expect(MetadataExtractor.parseTagNumber(atom: Data([0, 0, 1, 2, 0, 0])) == 258)
        #expect(MetadataExtractor.parseTagNumber(atom: Data([0, 0])) == nil)
    }

    // MARK: Fixture

    final class Directory: @unchecked Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("TrackNumberReaderTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func file(_ name: String) throws -> String {
            let file = url.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            return file.path
        }
    }

    /// Records which files were read and answers from a table keyed by file name.
    final class FakeExtractor: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [String] = []
        let numbers: [String: TrackNumbers]
        init(_ numbers: [String: TrackNumbers]) { self.numbers = numbers }
        var readNames: [String] { lock.lock(); defer { lock.unlock() }; return reads }
        func extract(_ url: URL) throws -> TrackNumbers {
            lock.lock(); reads.append(url.lastPathComponent); lock.unlock()
            guard let result = numbers[url.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
            return result
        }
    }

    private func make(titles: [String], files: Directory) throws -> (DatabaseQueue, Int64, [Int64]) {
        let db = try DatabaseManager.inMemory()
        let (album, ids): (Int64, [Int64]) = try db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('O','O','Good Lies','goodlies')")
            let album = db.lastInsertedRowID
            var ids: [Int64] = []
            for title in titles {
                let id = try AlbumTracksMigrationTests.insertTrack(db, title: title, album: "Good Lies", albumID: album)
                try db.execute(sql: "UPDATE tracks SET organized_path = ? WHERE id = ?", arguments: [try files.file("\(title).flac"), id])
                ids.append(id)
            }
            return (album, ids)
        }
        let repo = AlbumTrackRepository(database: db)
        _ = try db.write { db in
            for (id, key) in zip(ids, FractionalIndexer.evenlySpaced(count: ids.count)) {
                try AlbumTrack(albumId: album, trackId: id, disc: 1, position: key, trackNumber: nil).insert(db)
            }
        }
        _ = repo
        return (db, album, ids)
    }

    private func reader(_ db: DatabaseQueue, _ fake: FakeExtractor, connected: @escaping @Sendable () async -> Bool = { true },
                        pause: @escaping @Sendable () async -> Void = {}) -> TrackNumberReader {
        var reader = TrackNumberReader(database: db, libraryRoot: nil)
        reader.extract = { try fake.extract($0) }
        reader.isDriveConnected = connected
        reader.pause = pause
        return reader
    }

    // MARK: The job

    @Test func writesNumbersAndResortsWhenEveryTrackHasOne() async throws {
        let files = try Directory()
        let (db, album, ids) = try make(titles: ["A", "B", "C"], files: files)
        let fake = FakeExtractor(["A.flac": .init(track: 3, disc: 1), "B.flac": .init(track: 1, disc: 1), "C.flac": .init(track: 2, disc: 1)])
        let outcome = await reader(db, fake).run()
        #expect(outcome == .init(read: 3, withoutNumber: 0, unreadable: 0, albumsSorted: 1, cancelled: false))
        let rows = try await AlbumTrackRepository(database: db).rows(of: album)
        #expect(rows.map(\.trackId) == [ids[1], ids[2], ids[0]])
        #expect(rows.map(\.trackNumber) == [1, 2, 3])
    }

    @Test func discNumbersSortBeforeTrackNumbers() async throws {
        let files = try Directory()
        let (db, album, ids) = try make(titles: ["A", "B"], files: files)
        let fake = FakeExtractor(["A.flac": .init(track: 1, disc: 2), "B.flac": .init(track: 5, disc: 1)])
        _ = await reader(db, fake).run()
        let rows = try await AlbumTrackRepository(database: db).rows(of: album)
        #expect(rows.map(\.trackId) == [ids[1], ids[0]])
        #expect(rows.map(\.disc) == [1, 2])
    }

    @Test func aMissingNumberKeepsTheOrderAndIsCounted() async throws {
        let files = try Directory()
        let (db, album, ids) = try make(titles: ["A", "B", "C"], files: files)
        let fake = FakeExtractor(["A.flac": .init(track: 9, disc: nil), "B.flac": .init(track: nil, disc: nil), "C.flac": .init(track: 1, disc: nil)])
        let outcome = await reader(db, fake).run()
        #expect(outcome.read == 2 && outcome.withoutNumber == 1 && outcome.albumsSorted == 0)
        let rows = try await AlbumTrackRepository(database: db).rows(of: album)
        #expect(rows.map(\.trackId) == ids, "not complete: the order stays")
        #expect(rows.map(\.trackNumber) == [9, nil, 1])
    }

    @Test func aRunSkipsTracksThatAlreadyHaveANumber() async throws {
        let files = try Directory()
        let (db, album, ids) = try make(titles: ["A", "B", "C"], files: files)
        try await db.write { db in
            try db.execute(sql: "UPDATE album_tracks SET track_number = 4 WHERE track_id = ?", arguments: [ids[0]])
        }
        let fake = FakeExtractor(["B.flac": .init(track: 1, disc: 1), "C.flac": .init(track: 2, disc: 1)])
        let first = await reader(db, fake).run()
        #expect(first.read == 2)
        #expect(fake.readNames.sorted() == ["B.flac", "C.flac"], "A has its number and is not read")
        let second = await reader(db, fake).run()
        #expect(second == TrackNumberReader.Outcome(), "everything is numbered: nothing left to read")
        #expect(fake.readNames.count == 2)
        #expect(try await AlbumTrackRepository(database: db).rows(of: album).map(\.trackNumber) == [1, 2, 4])
        #expect(try await db.read { try TrackNumberReader.blockedReason($0) } == TrackNumberReader.nothingToRead)
    }

    @Test func aTrackWithoutAFileOrWithAnUnreadableFileIsCountedNotFatal() async throws {
        let files = try Directory()
        let (db, _, ids) = try make(titles: ["A", "B", "C"], files: files)
        try await db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = '/nonexistent/B.flac' WHERE id = ?", arguments: [ids[1]])
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL WHERE id = ?", arguments: [ids[2]])
        }
        let fake = FakeExtractor(["A.flac": .init(track: 1, disc: 1)])
        let outcome = await reader(db, fake).run()
        #expect(outcome.read == 1 && outcome.unreadable == 1)
        #expect(try await db.read { try TrackNumberReader.unreadCount($0) } == 1, "B stays to read; C has no file and is not counted")
    }

    @Test func waitsForTheDriveBeforeReading() async throws {
        let files = try Directory()
        let (db, _, _) = try make(titles: ["A"], files: files)
        let fake = FakeExtractor(["A.flac": .init(track: 1, disc: 1)])
        let checks = Counter()
        let outcome = await reader(db, fake, connected: { await checks.next() >= 3 }, pause: { await checks.paused() }).run()
        #expect(outcome.read == 1)
        #expect(await checks.pauses == 2, "paused twice, read once the drive was back")
    }

    @Test func cancellingWhileTheDriveIsAwayStopsWithoutReadingOrMarking() async throws {
        let files = try Directory()
        let (db, _, _) = try make(titles: ["A"], files: files)
        let fake = FakeExtractor(["A.flac": .init(track: 1, disc: 1)])
        let checks = Counter()
        let reader = reader(db, fake, connected: { _ = await checks.next(); return false }, pause: { try? await Task.sleep(for: .milliseconds(5)) })
        let task = Task { await reader.run() }
        // Cancel only once the run is really waiting for the drive (no fixed sleep).
        let deadline = ContinuousClock.now + .seconds(20)
        while await checks.checked < 2 {
            guard ContinuousClock.now < deadline else { Issue.record("the run never waited for the drive"); break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.cancelled && outcome.read == 0 && outcome.unreadable == 0)
        #expect(fake.readNames.isEmpty)
    }

    actor Counter {
        private(set) var checked = 0
        private(set) var pauses = 0
        func next() -> Int { checked += 1; return checked }
        func paused() { pauses += 1 }
    }

    // MARK: Import path

    @Test func anImportedTrackJoinsItsAlbumWithItsNumbers() throws {
        let db = try DatabaseManager.inMemory()
        try db.write { db in
            var ids: [Int64] = []
            for (title, number) in [("B", 2), ("A", 1)] {
                let id = try AlbumTracksMigrationTests.insertTrack(db, title: title, album: "Good Lies")
                _ = try AlbumTrackRepository.linkImportedTrack(db, trackID: id, artist: "Overmono", albumArtist: "Overmono",
                                                              album: "Good Lies", year: 2022, disc: 1, number: number)
                ids.append(id)
            }
            let none = try AlbumTracksMigrationTests.insertTrack(db, title: "N", album: "unknown album")
            #expect(try AlbumTrackRepository.linkImportedTrack(db, trackID: none, artist: "Overmono", albumArtist: "Overmono",
                                                              album: "unknown album", year: nil, disc: nil, number: nil) == nil)
            let rows = try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks ORDER BY disc, position")
            #expect(rows.map(\.trackId) == [ids[1], ids[0]], "every member numbered: sorted by number")
            #expect(rows.map(\.trackNumber) == [1, 2])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE title = 'Good Lies'") == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [ids[0]]) == rows[0].albumId)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks WHERE track_id = ?", arguments: [none]) == 0)
        }
    }

    // MARK: Menu

    @Test func theMenuItemIsAnAppItemInTheMaintenanceSubmenu() {
        let entry = MenuCommand.readTrackNumbers.entry
        #expect(entry.title == "Read Track Numbers")
        #expect(entry.parent == .maintenance)
        #expect(MaintenanceJob(action: MaintenanceJob.readTrackNumbers).readsAudioFiles)
        #expect(MaintenanceJob(action: MaintenanceJob.readTrackNumbers).title == "Read track numbers")
    }
}
