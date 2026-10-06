import Foundation
import Testing
@testable import MLM

/// W3-SET (ST-SRC.N04–N06, DEC-037): Settings ▸ Sources ▸ Download tools — found with version
/// and location, or `Not found` with the consequence and how to install. No process is run.
@Suite("Download tools (W3-SET)")
@MainActor
struct DownloadToolsModelTests {

    private struct Env: ToolEnvironment {
        let executables: [String: String]
        let versions: [String: String]
        func findExecutable(_ name: String) -> String? { executables[name] }
        func runVersionCommand(at path: String, arguments: [String]) async throws -> String? { versions[path] }
        func fileExists(atPath: String) -> Bool { false }
        func destinationOfSymbolicLink(atPath: String) -> String? { nil }
    }

    @Test func listsTheFourToolsWithStateWords() async {
        let env = Env(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp", "ffmpeg": "/opt/homebrew/bin/ffmpeg",
                          "scdl": "/Users/x/.local/bin/scdl"],
            versions: ["/opt/homebrew/bin/yt-dlp": "2026.09.12", "/opt/homebrew/bin/ffmpeg": "ffmpeg version 7.1 Copyright",
                       "/Users/x/.local/bin/scdl": "3.0.0"])
        let model = DownloadToolsModel(health: ExternalToolHealth(environment: env))
        await model.check()
        #expect(model.rows.map(\.name) == ["yt-dlp", "ffmpeg", "fpcalc", "scdl"])
        #expect(model.row(.ytdlp)?.statusText == "Found — 2026.09.12 at /opt/homebrew/bin/yt-dlp")
        #expect(model.row(.ffmpeg)?.statusText == "Found — 7.1 at /opt/homebrew/bin/ffmpeg")
        let fpcalc = model.row(.fpcalc)
        #expect(fpcalc?.statusText == "Not found · fingerprint analysis can’t run")
        #expect(fpcalc?.installCommand == "brew install chromaprint")
        #expect(fpcalc?.installIntro == "fpcalc is part of Chromaprint. In Terminal:")
        #expect(fpcalc?.installFooter == "Then press Check Again. Needed for: Fingerprint all tracks.")
        #expect(model.isMissing(.fpcalc))
        #expect(!model.isMissing(.scdl))
        #expect(model.checkedText?.hasPrefix("Checked today, ") == true)
    }

    @Test func checkAllStillReportsThePipelineOnly() async {
        let health = ExternalToolHealth(environment: Env(executables: [:], versions: [:]))
        let reports = await health.checkAll(latestVersions: [:])
        #expect(reports.map(\.name) == ["yt-dlp", "scdl", "ffmpeg", "ffprobe"])
    }

    @Test func settingsDates() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SettingsDate.text(now, now: now, calendar: calendar).hasPrefix("today, "))
        #expect(SettingsDate.text(now.addingTimeInterval(-86_400), now: now, calendar: calendar).hasPrefix("yesterday, "))
        #expect(SettingsDate.capitalized(now, now: now, calendar: calendar).hasPrefix("Today, "))
    }
}
