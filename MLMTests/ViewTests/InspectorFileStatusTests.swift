import Foundation
import Testing
@testable import MLM

/// Info ▸ File's availability sentence and fix per state (§15.4, §15.2, DEC-014), the tag-write
/// echo, and conformance of the rebuilt Info files (UC-COLOR-03, UC-COPY-01, PP-INSPECTOR-21).
@Suite("Info file status and conformance")
@MainActor
struct InspectorFileStatusTests {
    private func track(
        organized: String? = "Artist/a.m4a",
        missing: Bool = false,
        status: String? = nil,
        failure: TrackDownloadFailure? = nil,
        original: String = "https://soundcloud.com/a/b"
    ) throws -> Track {
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: original)
        track.id = 1
        track.organizedPath = organized
        track.fileMissingSince = missing ? "2026-10-01T00:00:00Z" : nil
        track.downloadStatus = status
        try track.setDownloadFailureRecord(failure)
        return track
    }

    private func status(_ track: Track, offline: (name: String, path: String)? = nil, volume: String? = "Lexxar", source: String? = "SoundCloud") -> InspectorFileStatus {
        InspectorFileStatus.make(track: track, availability: track.availability(), offlineVolume: offline,
                                 libraryVolumeName: volume, sourceName: source)
    }

    private let lexxar = (name: "Lexxar", path: "/Volumes/Lexxar")

    @Test func localNotDownloadedDownloading() throws {
        let local = status(try track())
        #expect(local.text == "On “Lexxar”, ready to play" && local.action == nil && local.isFileReachable)
        #expect(status(try track(), volume: nil).text == "On this Mac, ready to play")

        let notDownloaded = status(try track(organized: nil))
        #expect(notDownloaded.text == "Not downloaded")
        #expect(notDownloaded.detail == "MLM knows this track from SoundCloud but has no file yet.")
        #expect(notDownloaded.action == .download && notDownloaded.action?.title == "Download")

        let downloading = status(try track(organized: nil, status: "downloading"))
        #expect(downloading.text == "Downloading…" && downloading.showsProgress && downloading.action == nil)
    }

    @Test func downloadFailedSaysTheReasonAndOffersRetry() throws {
        let failed = status(try track(organized: nil, failure: TrackDownloadFailure(reason: "Sign-in expired (SoundCloud)", date: Date(), attempts: 1)))
        #expect(failed.text == "Download failed — Sign-in expired (SoundCloud)")
        #expect(failed.detail?.hasPrefix("2 attempts left · last tried") == true)
        #expect(failed.action == .retryDownload && failed.action?.title == "Retry Download")
        #expect(failed.tint == .attention)
    }

    @Test func fileMissingOffersDownloadAgainOnlyWithASource() throws {
        let missing = status(try track(missing: true))
        #expect(missing.text == "File missing" && missing.tint == .error)
        #expect(missing.action == .downloadAgain && missing.action?.title == "Download Again")
        #expect(status(try track(missing: true, original: "/Users/me/a.m4a")).action == nil, "an imported file has nothing to download")
    }

    @Test func driveNotConnectedIsNeverFileMissing() throws {
        for local in [try track(), try track(missing: true)] {
            let offline = status(local, offline: lexxar)
            #expect(offline.text == "“Lexxar” is not connected.")
            #expect(offline.action == nil, "the fix is the drive")
            #expect(!offline.isFileReachable)
            #expect(!offline.text.contains("missing") && !(offline.detail ?? "").contains("missing"))
        }
        // A file on another disk isn't affected by the library's disk.
        let elsewhere = status(try track(organized: "/Volumes/Other/a.m4a"), offline: lexxar)
        #expect(elsewhere.text == "On “Lexxar”, ready to play")
        // Not downloaded stays Not downloaded: the drive doesn't matter without a file.
        #expect(status(try track(organized: nil), offline: lexxar).text == "Not downloaded")
    }

    @Test func tagWriteEcho() {
        func pending(blocked: Bool = false, error: String? = nil) -> PendingTagWrite {
            PendingTagWrite(trackID: 1, fields: [.genre], staleSince: "x", revision: 1, attempts: 0,
                            lastAttemptAt: nil, lastError: error, blocked: blocked)
        }
        #expect(InspectorFileStatus.tagWriteEcho(nil, offlineVolumeName: "Lexxar") == nil)
        #expect(InspectorFileStatus.tagWriteEcho(pending(), offlineVolumeName: "Lexxar") == "Tag changes waiting for “Lexxar”")
        #expect(InspectorFileStatus.tagWriteEcho(pending(error: "the file is missing"), offlineVolumeName: nil) == "Tag changes waiting — the file is missing")
        #expect(InspectorFileStatus.tagWriteEcho(pending(blocked: true, error: "WAV isn’t supported"), offlineVolumeName: nil)
                == "Tag changes couldn’t be written to the file — WAV isn’t supported")
    }

    @Test func severalTracksSummary() {
        #expect(InspectorFileStatus.summary([.local, .local, .notDownloaded, .fileMissing]) == "2 local · 1 not downloaded · 1 file missing")
    }

    @Test func headerFormatLineNeverShowsASourceAsFormat() throws {
        var notDownloaded = try track(organized: nil)
        notDownloaded.format = "soundcloud"
        notDownloaded.duration = 311
        #expect(InspectorHeader.formatLine(notDownloaded) == "Not downloaded · 5:11")
        var local = try track()
        local.bitrate = 256
        local.duration = 372
        #expect(InspectorHeader.formatLine(local) == "M4A · 256 kbps · 6:12")
    }

    // MARK: Conformance of the rebuilt files

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let rebuilt = [
        "MLM/Views/Inspector/InspectorView.swift", "MLM/Views/Inspector/InspectorDetailsTab.swift",
        "MLM/Views/Inspector/InspectorAudioTab.swift", "MLM/Views/Inspector/InspectorFileTab.swift",
        "MLM/Views/Inspector/InspectorModel.swift", "MLM/Views/Inspector/InspectorFileStatus.swift",
        "MLM/Views/Inspector/InspectorAnalysis.swift", "MLM/Views/TrackDetail/WaveformView.swift",
        "MLM/Views/TrackDetail/WaveformHelpers.swift", "MLM/Views/Shell/TrailingColumnView.swift",
    ]

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func noCustomTokensFontsOrGerman() throws {
        for path in Self.rebuilt {
            let code = try source(path).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains(".mlm") && !code.contains("Color.mlm") && !code.contains("MLMFont"), "\(path): UC-COLOR-03 / UC-TYPE-01")
            #expect(!code.contains(".system(size"), "\(path): system text styles only")
            for german in ["Neuer", "kanonisch", "z.B.", "Genre-Name", "Speichern", "Abbrechen"] {
                #expect(!code.contains(german), "\(path): English only")
            }
            #expect(!code.contains("#available"), "\(path): no availability checks")
        }
    }

    @Test func noSimilarSheetOrDeleteAndNoAutoOpen() throws {
        for path in Self.rebuilt {
            let code = try source(path)
            #expect(!code.contains("GrooveView("), "\(path): the Similar sheet with its Delete isn't hosted (PP-INSPECTOR-21)")
            #expect(!code.contains("trashItem") && !code.contains("role: .destructive"), "\(path): nothing destructive in Info")
            #expect(!code.contains("Genre Workshop"), "\(path): PP-INSPECTOR-26")
        }
        let view = try source("MLM/Views/Inspector/InspectorView.swift")
        #expect(!view.contains("toggle(.info)") && !view.contains("isPresented = true"), "Info never opens itself (UC-TRAIL-02)")
        #expect(!view.contains("currentTrack"), "Info never follows the playing track (UC-TRAIL-03)")
        #expect(InspectorTab.allCases.map(\.title) == ["Details", "Audio", "File"])
    }
}
