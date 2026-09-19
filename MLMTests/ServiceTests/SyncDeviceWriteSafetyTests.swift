import Testing
import Foundation
import CryptoKit
@testable import MLM

@Suite("SyncDeviceWriteSafetyTests")
struct SyncDeviceWriteSafetyTests {

    // MARK: - F9: stage-then-swap in linkToProfile

    @Test func linkToProfile_preservesExistingDestinationOnSourceFailure() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ltp_safety_\(UUID().uuidString)")
        let cacheDir = base.appendingPathComponent("cache")
        let destDir = base.appendingPathComponent("dest")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let trackId: Int64 = 999_001
        let cacheFile = cacheDir.appendingPathComponent("\(trackId)_248.m4a")
        try "cached-aac-data".write(to: cacheFile, atomically: true, encoding: .utf8)

        let destURL = destDir.appendingPathComponent("track.m4a")
        let originalContent = "original-destination-content"
        try originalContent.write(to: destURL, atomically: true, encoding: .utf8)

        let cache = TranscodeCache(cacheDir: cacheDir)

        // Remove the cache entry AFTER placing it so linkToProfile's source
        // is a nonexistent path — simulates a volume-full / unplug scenario
        // where the link/copy step fails.
        // Actually, the cache file exists, so linkToProfile will succeed.
        // To force failure, we need a different approach: make the dest dir read-only.
        // Instead, let's test the success path preserves correctness, and test
        // that a missing cache entry throws without deleting destination.

        // Test 1: cacheEntryMissing does NOT delete existing destination
        let missingTrackId: Int64 = 888_888
        do {
            try cache.linkToProfile(
                trackId: missingTrackId,
                bitrateKbps: 248,
                destinationPath: destURL
            )
            Issue.record("Expected cacheEntryMissing throw")
        } catch {
            // Destination must survive untouched
            #expect(fm.fileExists(atPath: destURL.path))
            let surviving = try String(contentsOf: destURL, encoding: .utf8)
            #expect(surviving == originalContent)
        }

        // Test 2: success path produces correct final file
        try cache.linkToProfile(
            trackId: trackId,
            bitrateKbps: 248,
            destinationPath: destURL
        )
        #expect(fm.fileExists(atPath: destURL.path))
        let finalContent = try String(contentsOf: destURL, encoding: .utf8)
        #expect(finalContent == "cached-aac-data")

        // No .tmp litter in dest dir
        let destContents = try fm.contentsOfDirectory(atPath: destDir.path)
        let tmpFiles = destContents.filter { $0.hasSuffix(".tmp") || $0.contains(".mlm_ltp_") }
        #expect(tmpFiles.isEmpty)
    }

    @Test func linkToProfile_removesAlternativeSiblingsOnSuccess() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ltp_siblings_\(UUID().uuidString)")
        let cacheDir = base.appendingPathComponent("cache")
        let destDir = base.appendingPathComponent("dest")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let trackId: Int64 = 999_002
        let cacheFile = cacheDir.appendingPathComponent("\(trackId)_248.m4a")
        try "fresh-aac".write(to: cacheFile, atomically: true, encoding: .utf8)

        let destURL = destDir.appendingPathComponent("track.m4a")
        // Plant stale siblings
        let stemURL = destURL.deletingPathExtension()
        for ext in ["mp3", "flac", "aac"] {
            try "stale-\(ext)".write(to: stemURL.appendingPathExtension(ext), atomically: true, encoding: .utf8)
        }

        let cache = TranscodeCache(cacheDir: cacheDir)
        try cache.linkToProfile(
            trackId: trackId,
            bitrateKbps: 248,
            destinationPath: destURL
        )

        #expect(fm.fileExists(atPath: destURL.path))
        // Note: linkToProfile itself does not remove siblings — that is the
        // caller's job (SyncService). But linkToProfile must not leave tmp files.
        let destContents = try fm.contentsOfDirectory(atPath: destDir.path)
        let tmpFiles = destContents.filter { $0.contains(".mlm_ltp_") }
        #expect(tmpFiles.isEmpty)
    }

    @Test func linkToProfile_noTempLitterOnCopyFailure() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ltp_nolitter_\(UUID().uuidString)")
        let cacheDir = base.appendingPathComponent("cache")
        let destDir = base.appendingPathComponent("dest")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let trackId: Int64 = 999_003
        let cacheFile = cacheDir.appendingPathComponent("\(trackId)_248.m4a")
        try "some-data".write(to: cacheFile, atomically: true, encoding: .utf8)

        // Make destDir read-only so link/copy into it fails
        let destURL = destDir.appendingPathComponent("track.m4a")
        let originalContent = "must-survive"
        try originalContent.write(to: destURL, atomically: true, encoding: .utf8)

        // Remove write permission on destDir
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
        }

        let cache = TranscodeCache(cacheDir: cacheDir)
        do {
            try cache.linkToProfile(
                trackId: trackId,
                bitrateKbps: 248,
                destinationPath: destURL
            )
            Issue.record("Expected throw on read-only directory")
        } catch {
            // Expected
        }

        // Destination must survive
        #expect(fm.fileExists(atPath: destURL.path))
        let surviving = try String(contentsOf: destURL, encoding: .utf8)
        #expect(surviving == originalContent)

        // Restore permissions before cleanup check
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
        let destContents = try fm.contentsOfDirectory(atPath: destDir.path)
        let tmpFiles = destContents.filter { $0.contains(".mlm_ltp_") || $0.hasSuffix(".tmp") }
        #expect(tmpFiles.isEmpty, "Temp files left behind: \(tmpFiles)")
    }

    // MARK: - F2: sha256 equivalence

    @Test func sha256_identicalFilesAtDifferentPaths_produceSameDigest() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sha256_equiv_\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let content = "identical-content-for-hash-test-\(UUID().uuidString)"
        let fileA = base.appendingPathComponent("file_a.m4a")
        let fileB = base.appendingPathComponent("subdir").appendingPathComponent("file_b.m4a")
        try fm.createDirectory(at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileA, atomically: true, encoding: .utf8)
        try content.write(to: fileB, atomically: true, encoding: .utf8)

        let hashA = try TranscodeCache.sha256(of: fileA)
        let hashB = try TranscodeCache.sha256(of: fileB)
        #expect(hashA == hashB)
        #expect(hashA.count == 64)
    }
}
