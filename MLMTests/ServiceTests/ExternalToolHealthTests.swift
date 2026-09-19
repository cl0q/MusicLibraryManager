import Foundation
import Testing
@testable import MLM

/// Tests for external download-tool health reporting.
///
/// Fully hermetic: every test injects a `FakeEnvironment` so nothing
/// shells out, nothing touches the network, and results do not depend
/// on what happens to be installed on the machine running the tests.
struct ExternalToolHealthTests {

    // MARK: - Fake environment

    /// Records every call so tests can assert that only version probes
    /// ran (no upgrades, no mutations).
    private final class FakeEnvironment: ToolEnvironment, @unchecked Sendable {
        var executables: [String: String]
        var versionOutputs: [String: String]
        var existingFiles: Set<String>
        var symlinkTargets: [String: String]

        private let lock = NSLock()
        private var _invocations: [String] = []

        var invocations: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _invocations
        }

        init(
            executables: [String: String] = [:],
            versionOutputs: [String: String] = [:],
            existingFiles: Set<String> = [],
            symlinkTargets: [String: String] = [:]
        ) {
            self.executables = executables
            self.versionOutputs = versionOutputs
            self.existingFiles = existingFiles
            self.symlinkTargets = symlinkTargets
        }

        func findExecutable(_ name: String) -> String? {
            record("find:\(name)")
            return executables[name]
        }

        func runVersionCommand(at path: String, arguments: [String]) async throws -> String? {
            record("run:\(path):\(arguments.joined(separator: " "))")
            return versionOutputs[path]
        }

        func fileExists(atPath: String) -> Bool {
            record("exists:\(atPath)")
            return existingFiles.contains(atPath)
        }

        func destinationOfSymbolicLink(atPath: String) -> String? {
            record("symlink:\(atPath)")
            return symlinkTargets[atPath]
        }

        private func record(_ s: String) {
            lock.lock()
            defer { lock.unlock() }
            _invocations.append(s)
        }
    }

    // MARK: - ToolVersion parsing

    @Test func parseCalendarVersion() {
        let v = ToolVersion("2026.07.04")
        #expect(v != nil)
        #expect(v?.components == [2026, 7, 4])
    }

    @Test func parseSemver() {
        let v = ToolVersion("3.0.4")
        #expect(v != nil)
        #expect(v?.components == [3, 0, 4])
    }

    @Test func parseVersionFromFfmpegOutput() {
        let v = ToolVersion("ffmpeg version 8.1.1 Copyright (c) 2024")
        #expect(v != nil)
        #expect(v?.components == [8, 1, 1])
    }

    @Test func parseVersionWithBuildMetadata() {
        let v = ToolVersion("8.1.1-tessus-build123")
        #expect(v != nil)
        #expect(v?.components == [8, 1, 1])
    }

    @Test func parseVersionWithVPrefix() {
        let v = ToolVersion("v2026.07.04")
        #expect(v != nil)
        #expect(v?.components == [2026, 7, 4])
    }

    @Test func parseGarbageVersionReturnsNil() {
        #expect(ToolVersion("not a version at all") == nil)
    }

    @Test func parseEmptyVersionReturnsNil() {
        #expect(ToolVersion("") == nil)
    }

    // MARK: - ToolVersion comparison

    @Test func calendarVersionOutdated() {
        let installed = ToolVersion("2026.07.04")!
        let latest = ToolVersion("2026.08.19")!
        #expect(installed < latest)
    }

    @Test func calendarVersionEqual() {
        let a = ToolVersion("2026.08.19")!
        let b = ToolVersion("2026.08.19")!
        #expect(a == b)
        #expect(!(a < b))
    }

    @Test func newerThanLatestIsNotOutdated() {
        let installed = ToolVersion("2026.09.01")!
        let latest = ToolVersion("2026.08.19")!
        #expect(!(installed < latest))
    }

    /// String comparison gets this wrong: "3.0.9" > "3.0.10".
    /// Numeric component comparison must get it right.
    @Test func semverTrap309vs3010() {
        let older = ToolVersion("3.0.9")!
        let newer = ToolVersion("3.0.10")!
        #expect(older < newer)
    }

    @Test func differingComponentCounts() {
        let short = ToolVersion("8.1")!
        let long = ToolVersion("8.1.1")!
        #expect(short < long)
    }

    @Test func buildMetadataIgnoredInComparison() {
        let withBuild = ToolVersion("8.1.1-tessus")!
        let plain = ToolVersion("8.1.1")!
        #expect(withBuild == plain)
    }

    // MARK: - Status logic

    @Test func missingBinaryReportsMissing() async {
        let env = FakeEnvironment()
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .missing)
        #expect(!report.installed)
        #expect(report.path == nil)
    }

    @Test func installedAndCurrentReportsOk() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.08.19"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .ok)
        #expect(report.installed)
        #expect(report.versionString == "2026.08.19")
    }

    @Test func installedAndOlderReportsOutdated() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.07.04"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .outdated)
        #expect(report.installed)
        #expect(report.versionString == "2026.07.04")
    }

    @Test func installedButUnparseableVersionReportsUnknown() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "garbage output"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .unknown)
        #expect(report.installed)
    }

    @Test func noLatestVersionProvidedReportsUnknown() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.07.04"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: nil)
        #expect(report.status == .unknown)
        #expect(report.installed)
    }

    @Test func versionCommandFailsReportsUnknown() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"]
            // versionOutputs intentionally empty → runVersionCommand returns nil
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .unknown)
        #expect(report.installed)
    }

    // MARK: - scdl bundled yt-dlp

    @Test func scdlBundledYtDlpOutdatedMentionsPipx() async {
        let scdlPath = "/Users/olli/.local/bin/scdl"
        let venvYtDlp = "/Users/olli/.local/pipx/venvs/scdl/bin/yt-dlp"
        let env = FakeEnvironment(
            executables: ["scdl": scdlPath],
            versionOutputs: [
                scdlPath: "3.0.4",
                venvYtDlp: "2026.3.17",
            ],
            existingFiles: [venvYtDlp],
            symlinkTargets: [scdlPath: "/Users/olli/.local/pipx/venvs/scdl/bin/scdl"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.scdl, latestVersion: "2026.08.19")

        #expect(report.bundledYtDlp != nil)
        #expect(report.bundledYtDlp?.status == .outdated)
        #expect(report.bundledYtDlp?.versionString == "2026.3.17")

        let bundledMessage = report.bundledYtDlp?.message ?? ""
        #expect(bundledMessage.contains("pipx"))
    }

    /// The bundled-scdl remedy must NOT tell the user to run
    /// `brew upgrade yt-dlp` — that updates the system copy, not the
    /// venv copy scdl actually delegates to.
    @Test func scdlBundledYtDlpMessageDoesNotSayBrewUpgradeYtDlp() async {
        let scdlPath = "/Users/olli/.local/bin/scdl"
        let venvYtDlp = "/Users/olli/.local/pipx/venvs/scdl/bin/yt-dlp"
        let env = FakeEnvironment(
            executables: ["scdl": scdlPath],
            versionOutputs: [
                scdlPath: "3.0.4",
                venvYtDlp: "2026.3.17",
            ],
            existingFiles: [venvYtDlp],
            symlinkTargets: [scdlPath: "/Users/olli/.local/pipx/venvs/scdl/bin/scdl"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.scdl, latestVersion: "2026.08.19")

        let bundledMessage = report.bundledYtDlp?.message ?? ""
        #expect(!bundledMessage.contains("brew upgrade yt-dlp"))
    }

    @Test func scdlBundledYtDlpCannotDetermineReportsUnknown() async {
        // scdl installed but not via pipx — no symlink to a venv
        let scdlPath = "/usr/local/bin/scdl"
        let env = FakeEnvironment(
            executables: ["scdl": scdlPath],
            versionOutputs: [scdlPath: "3.0.4"],
            symlinkTargets: [:]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.scdl, latestVersion: "2026.08.19")

        // bundledYtDlp should be nil (can't determine) or .unknown
        if let bundled = report.bundledYtDlp {
            #expect(bundled.status == .unknown)
        }
        // Main report must reflect the uncertainty
        #expect(report.status == .unknown)
    }

    // MARK: - Message quality

    @Test func outdatedMessageContainsInstalledVersion() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.07.04"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.message.contains("2026.07.04"))
    }

    @Test func outdatedMessageContainsRemedyCommand() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.07.04"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(
            report.message.contains("brew upgrade yt-dlp")
                || report.message.contains("yt-dlp -U")
        )
    }

    @Test func missingMessageIsNonEmpty() async {
        let env = FakeEnvironment()
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ffmpeg, latestVersion: "8.1.1")
        #expect(report.status == .missing)
        #expect(!report.message.isEmpty)
    }

    @Test func unknownMessageIsNonEmpty() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "garbage"]
        )
        let health = ExternalToolHealth(environment: env)
        let report = await health.check(.ytdlp, latestVersion: "2026.08.19")
        #expect(report.status == .unknown)
        #expect(!report.message.isEmpty)
    }

    // MARK: - Side-effect freedom

    /// Checking health must only run version probes — never upgrades.
    @Test func healthCheckOnlyRunsVersionQueries() async {
        let env = FakeEnvironment(
            executables: ["yt-dlp": "/opt/homebrew/bin/yt-dlp"],
            versionOutputs: ["/opt/homebrew/bin/yt-dlp": "2026.07.04"]
        )
        let health = ExternalToolHealth(environment: env)
        _ = await health.check(.ytdlp, latestVersion: "2026.08.19")

        let runInvocations = env.invocations.filter { $0.hasPrefix("run:") }
        for invocation in runInvocations {
            #expect(
                invocation.contains("--version") || invocation.contains("-version"),
                "Expected only version probes, got: \(invocation)"
            )
        }
        let upgradeInvocations = env.invocations.filter {
            $0.contains("-U") || $0.contains("upgrade")
        }
        #expect(upgradeInvocations.isEmpty)
    }

    // MARK: - checkAll

    @Test func checkAllReportsAllTools() async {
        let env = FakeEnvironment(
            executables: [
                "yt-dlp": "/opt/homebrew/bin/yt-dlp",
                "ffmpeg": "/opt/homebrew/bin/ffmpeg",
                "ffprobe": "/opt/homebrew/bin/ffprobe",
                // scdl intentionally absent
            ],
            versionOutputs: [
                "/opt/homebrew/bin/yt-dlp": "2026.08.19",
                "/opt/homebrew/bin/ffmpeg": "ffmpeg version 8.1.1 Copyright",
                "/opt/homebrew/bin/ffprobe": "ffprobe version 8.1.1 Copyright",
            ]
        )
        let health = ExternalToolHealth(environment: env)
        let reports = await health.checkAll(latestVersions: [
            .ytdlp: "2026.08.19",
            .scdl: "3.0.4",
            .ffmpeg: "8.1.1",
            .ffprobe: "8.1.1",
        ])
        #expect(reports.count == 4)

        let byName = Dictionary(uniqueKeysWithValues: reports.map { ($0.name, $0) })
        #expect(byName["yt-dlp"]?.status == .ok)
        #expect(byName["scdl"]?.status == .missing)
        #expect(byName["ffmpeg"]?.status == .ok)
        #expect(byName["ffprobe"]?.status == .ok)
    }
}
