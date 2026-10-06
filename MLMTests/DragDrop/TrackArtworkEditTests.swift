import AppKit
import Foundation
import GRDB
import Testing
@testable import MLM

/// W5-1a G25: an image dropped on the Info cover is one undoable `Set Artwork`; the track drags
/// out of it (D-TD-ARTWORK-IN, D-TD-TRACK-OUT).
@MainActor
@Suite("TrackArtworkEditTests")
struct TrackArtworkEditTests {
    struct Env {
        let db: DatabaseQueue
        let analysis: AnalysisRepository
        let manager: UndoManager
        let undo: UndoCenter
        let status: StatusBarCenter
        let edit: TrackArtworkEdit
        let folder: URL
        let ids: [Int64]
    }

    private func makeEnv() async throws -> Env {
        let db = try DatabaseManager.inMemory()
        let ids: [Int64] = try await db.write { db in
            try (0..<2).map { try AlbumTracksMigrationTests.insertTrack(db, title: "T\($0)", album: "Low Season") }
        }
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MLM-track-art-\(UUID().uuidString)", isDirectory: true)
        let analysis = AnalysisRepository(database: db)
        var edit = TrackArtworkEdit(analysis: analysis, cacheDirectory: folder, undo: undo, notificationCenter: NotificationCenter())
        edit.notificationCenter = NotificationCenter()
        return Env(db: db, analysis: analysis, manager: manager, undo: undo, status: status, edit: edit, folder: folder, ids: ids)
    }

    private func png(_ size: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<size { for y in 0..<size { rep.setColor(.init(red: CGFloat(x) / CGFloat(size), green: 0.4, blue: 0.2, alpha: 1), atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func settingArtworkIsOneStepForEverySelectedTrackAndUndoPutsBackNothing() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.folder) }
        let image = try png(16)
        let refusal = await env.edit.set(.data(image), trackIDs: env.ids, title: nil)
        #expect(refusal == nil)
        for id in env.ids {
            let row = try #require(try await env.analysis.fetchArtwork(trackId: id))
            #expect(row.source == "user")
            #expect(FileManager.default.fileExists(atPath: try #require(row.artworkPath)))
        }
        #expect(env.status.message?.text == "Set the artwork of 2 tracks")
        #expect(env.manager.undoMenuItemTitle == "Undo Set Artwork")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        for id in env.ids {
            #expect(try await env.analysis.fetchArtwork(trackId: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: env.folder.appendingPathComponent("\(id)_1200.jpg").path))
        }
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await env.analysis.fetchArtwork(trackId: env.ids[0])?.source == "user")
    }

    @Test func undoRestoresTheEarlierRowAndFilesExactly() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.folder) }
        let id = env.ids[0]
        let first = try png(16), second = try png(32)
        _ = await env.edit.set(.data(first), trackIDs: [id], title: "T0")
        #expect(env.status.message?.text == "Set the artwork of “T0”")
        let large = env.folder.appendingPathComponent("\(id)_1200.jpg")
        let afterFirst = try Data(contentsOf: large)
        let rowAfterFirst = try await env.analysis.fetchArtwork(trackId: id)
        _ = await env.edit.set(.data(second), trackIDs: [id], title: "T0")
        #expect(try Data(contentsOf: large) != afterFirst)
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try Data(contentsOf: large) == afterFirst)
        let restored = try await env.analysis.fetchArtwork(trackId: id)
        #expect(restored?.artworkPath == rowAfterFirst?.artworkPath && restored?.source == rowAfterFirst?.source)
    }

    @Test func somethingThatIsNotAnImageIsRefusedAndWritesNothing() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.folder) }
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        let refusal = await env.edit.set(.file(text), trackIDs: env.ids, title: nil)
        #expect(refusal == "Couldn’t use “\(text.lastPathComponent)” as a cover. Drop a PNG, JPEG or HEIC image.")
        #expect(await env.edit.set(.data(Data([1, 2, 3])), trackIDs: env.ids, title: nil)
                == "Couldn’t use that image as a cover. Drop a PNG, JPEG or HEIC image.")
        #expect(!env.manager.canUndo)
        #expect(try await env.analysis.fetchArtwork(trackId: env.ids[0]) == nil)
    }

    @Test func theInfoCoverIsADropTargetForImagesOnly() throws {
        let context = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)
        let target = DropTarget.trackArtwork(ids: [4, 5], title: nil)
        let image = Data([1, 2, 3])
        #expect(DropRules.decide(.imageData(image), onto: target, context: context)
                == .setTrackArtwork(.data(image), trackIDs: [4, 5], title: nil))
        let url = URL(fileURLWithPath: "/tmp/cover.png")
        #expect(DropRules.decide(.files([DroppedFile(url: url, kind: .image)]), onto: target, context: context)
                == .setTrackArtwork(.file(url), trackIDs: [4, 5], title: nil))
        let audio = DroppedFile(url: URL(fileURLWithPath: "/tmp/a.flac"), kind: .audio)
        #expect(DropRules.decide(.files([audio]), onto: target, context: context)
                == .refuse(DropWords.notACover(fileName: "a.flac")))
        let tracks = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "lib")])
        #expect(DropRules.decide(.tracks(tracks), onto: target, context: context) == .refuse(nil))
        #expect(DropRules.accepts(.imageData, on: target, context: context))
        #expect(DropRules.accepts(.files, on: target, context: context))
        #expect(!DropRules.accepts(.tracks, on: target, context: context))
    }

    @Test func theInfoHeaderDragsOneTrackOut() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MLM/Views/Inspector/InspectorView.swift"), encoding: .utf8)
        #expect(text.contains(".draggable(dragItem(track))"))
        #expect(text.contains(".dropTarget(.trackArtwork("))
    }
}
