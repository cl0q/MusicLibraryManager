import Foundation
import Observation

/// One row of Settings ▸ Sources ▸ Download tools (ST-SRC.N04/N05, DEC-037, UC §15.3): found
/// with version and location, or `Not found` with what stops working and how to install it.
struct DownloadToolRow: Identifiable, Equatable, Sendable {
    let tool: ExternalToolHealth.Tool
    let isFound: Bool
    /// `2026.09.12`, `7.1`; `nil` when unknown.
    let version: String?
    let path: String?

    var id: String { tool.rawValue }
    var name: String { tool.rawValue }

    /// What the tool is for (right-hand caption): `YouTube downloads`.
    var neededFor: String { Self.purpose(tool) }

    /// `Found — 2026.09.12 at /opt/homebrew/bin/yt-dlp` · `Not found · fingerprint analysis can’t run`.
    var statusText: String {
        guard isFound else { return "Not found · \(Self.consequence(tool))" }
        var text = "Found"
        if let version { text += " — \(version)" }
        if let path { text += version == nil ? " — at \(path)" : " at \(path)" }
        return text
    }

    /// The `How to Install` popover (ST-SRC.N06).
    var installTitle: String { "Install \(name)" }
    var installIntro: String { Self.intro(tool) }
    var installCommand: String { Self.command(tool) }
    var installFooter: String { "Then press Check Again. Needed for: \(Self.jobs(tool))." }

    static func purpose(_ tool: ExternalToolHealth.Tool) -> String {
        switch tool {
        case .ytdlp: "YouTube downloads"
        case .ffmpeg: "Transcoding, artwork, analysis"
        case .ffprobe: "Reading audio details"
        case .fpcalc: "Fingerprint analysis"
        case .scdl: "SoundCloud downloads"
        }
    }

    static func consequence(_ tool: ExternalToolHealth.Tool) -> String {
        switch tool {
        case .ytdlp: "YouTube downloads can’t run"
        case .ffmpeg: "transcoding, artwork and analysis can’t run"
        case .ffprobe: "audio details can’t be read"
        case .fpcalc: "fingerprint analysis can’t run"
        case .scdl: "SoundCloud downloads can’t run"
        }
    }

    static func intro(_ tool: ExternalToolHealth.Tool) -> String {
        switch tool {
        case .fpcalc: "fpcalc is part of Chromaprint. In Terminal:"
        case .ffprobe: "ffprobe is part of ffmpeg. In Terminal:"
        case .scdl: "scdl is installed with pipx. In Terminal:"
        case .ytdlp, .ffmpeg: "In Terminal:"
        }
    }

    static func command(_ tool: ExternalToolHealth.Tool) -> String {
        switch tool {
        case .ytdlp: "brew install yt-dlp"
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        case .fpcalc: "brew install chromaprint"
        case .scdl: "pipx install scdl"
        }
    }

    static func jobs(_ tool: ExternalToolHealth.Tool) -> String {
        switch tool {
        case .ytdlp: "YouTube downloads and the fallback for other sources"
        case .ffmpeg, .ffprobe: "transcoding for sync, artwork, ReplayGain, danceability and similarity analysis"
        case .fpcalc: "Fingerprint all tracks"
        case .scdl: "SoundCloud downloads"
        }
    }
}

/// The Download tools state, re-checked when the Sources tab appears and on `Check Again`. The
/// probes run off the main actor and never block the UI (DEC-037).
@MainActor
@Observable
final class DownloadToolsModel {
    static let shared = DownloadToolsModel()

    /// The tools Settings lists, in the mockup's order.
    nonisolated static let listed: [ExternalToolHealth.Tool] = [.ytdlp, .ffmpeg, .fpcalc, .scdl]

    private(set) var rows: [DownloadToolRow] = []
    private(set) var checkedAt: Date?
    private(set) var isChecking = false

    @ObservationIgnored private let health: ExternalToolHealth
    @ObservationIgnored private let now: @Sendable () -> Date

    init(health: ExternalToolHealth = ExternalToolHealth(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.health = health
        self.now = now
    }

    func row(_ tool: ExternalToolHealth.Tool) -> DownloadToolRow? {
        rows.first { $0.tool == tool }
    }

    /// Whether `tool` was found at the last check (`nil` before the first one).
    func isMissing(_ tool: ExternalToolHealth.Tool) -> Bool {
        row(tool).map { !$0.isFound } ?? false
    }

    /// Probes every listed tool; a second call while one runs does nothing.
    func check() async {
        // A second caller waits for the running check instead of reading stale rows.
        if let running = runningCheck {
            await running.value
            return
        }
        let task = Task { await performCheck() }
        runningCheck = task
        await task.value
        runningCheck = nil
    }

    @ObservationIgnored private var runningCheck: Task<Void, Never>?

    private func performCheck() async {
        isChecking = true
        defer { isChecking = false }
        let health = health
        let reports = await Task.detached(priority: .utility) {
            var reports: [DownloadToolRow] = []
            for tool in Self.listed {
                let report = await health.check(tool, latestVersion: nil)
                reports.append(DownloadToolRow(
                    tool: tool, isFound: report.installed,
                    version: report.parsedVersion?.raw, path: report.path))
            }
            return reports
        }.value
        rows = reports
        checkedAt = now()
    }

    /// `Checked today, 09:14`.
    var checkedText: String? {
        checkedAt.map { "Checked \(SettingsDate.text($0, now: now()))" }
    }
}
