import Foundation

// MARK: - ToolVersion

/// Parsed dotted-numeric version for comparison.
///
/// Extracts the leading dotted-numeric prefix from a version string and
/// ignores trailing non-numeric build metadata. This handles every scheme
/// the download tools use:
///
/// - Calendar versions: `"2026.07.04"` → `[2026, 7, 4]`
/// - Semver: `"3.0.4"` → `[3, 0, 4]`
/// - Build metadata: `"8.1.1-tessus"` → `[8, 1, 1]`
/// - Prefixed output: `"ffmpeg version 8.1.1 Copyright …"` → `[8, 1, 1]`
///
/// **Why not plain string comparison?** `"3.0.9" > "3.0.10"` as strings
/// because `"9" > "1"`, but numerically `9 < 10`. Component-wise integer
/// comparison gets this right. Missing components are treated as `0`, so
/// `"8.1" < "8.1.1"` (i.e. `[8,1,0] < [8,1,1]`).
struct ToolVersion: Sendable, Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    let raw: String

    /// Parse a version string. Returns `nil` when no dotted-numeric
    /// prefix can be found (garbage, empty string, etc.).
    init?(_ string: String) {
        guard let firstDigit = string.firstIndex(where: { $0.isNumber }) else {
            return nil
        }

        var comps: [Int] = []
        var current = ""
        var idx = firstDigit

        while idx < string.endIndex {
            let ch = string[idx]
            if ch.isNumber {
                current.append(ch)
            } else if ch == "." && !current.isEmpty {
                comps.append(Int(current)!)
                current = ""
            } else {
                break
            }
            idx = string.index(after: idx)
        }
        if !current.isEmpty {
            comps.append(Int(current)!)
        }

        guard !comps.isEmpty else { return nil }
        self.components = comps
        self.raw = String(string[firstDigit..<idx])
    }

    var description: String { raw }

    /// Component-wise comparison; missing components treated as 0.
    static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l < r { return true }
            if l > r { return false }
        }
        return false // equal
    }
}

// MARK: - ToolHealthStatus

/// Health status for a single external tool.
enum ToolHealthStatus: Sendable {
    /// Binary not found on the system.
    case missing
    /// Installed and version is current (>= latest known).
    case ok
    /// Installed but version is older than the latest known.
    case outdated
    /// Installed but version could not be determined, or no latest
    /// version was supplied for comparison.
    case unknown
}

// MARK: - BundledYtDlpHealth

/// Health of the yt-dlp copy bundled inside scdl's pipx venv.
///
/// scdl delegates SoundCloud extraction to yt-dlp, but a pipx install
/// bundles its own yt-dlp inside the venv — `brew upgrade yt-dlp` never
/// touches it. This type reports that hidden copy's version and staleness.
struct BundledYtDlpHealth: Sendable {
    let path: String?
    let versionString: String?
    let parsedVersion: ToolVersion?
    let status: ToolHealthStatus
    let message: String
}

// MARK: - ToolHealth

/// Health report for a single external tool.
struct ToolHealth: Sendable {
    /// Display name matching the binary name (e.g. "yt-dlp", "scdl").
    let name: String
    /// Resolved absolute path, or `nil` when not installed.
    let path: String?
    let installed: Bool
    /// Raw version string from `--version` / `-version`, trimmed.
    let versionString: String?
    /// Parsed comparable version, or `nil` when unparseable.
    let parsedVersion: ToolVersion?
    let status: ToolHealthStatus
    /// The latest-known version that was supplied for comparison.
    let latestKnownVersion: String?
    /// Human-readable, actionable message. Empty for `.ok`.
    let message: String
    /// Present only for scdl — the bundled yt-dlp health.
    let bundledYtDlp: BundledYtDlpHealth?
}

// MARK: - ToolEnvironment (injectable seam)

/// Abstraction over the I/O that `ExternalToolHealth` needs so that
/// tests can run without shelling out.
protocol ToolEnvironment: Sendable {
    /// Resolve a binary name to an absolute path (wraps `ProcessRunner.findExecutable`).
    func findExecutable(_ name: String) -> String?
    /// Run a binary with the given arguments and return stdout, or `nil` on failure.
    func runVersionCommand(at path: String, arguments: [String]) async throws -> String?
    /// Check whether a file exists at the given path.
    func fileExists(atPath: String) -> Bool
    /// Resolve a symbolic link to its target, or `nil` if not a symlink.
    func destinationOfSymbolicLink(atPath: String) -> String?
}

// MARK: - LiveToolEnvironment

/// Production environment that delegates to `ProcessRunner` and `FileManager`.
struct LiveToolEnvironment: ToolEnvironment {
    func findExecutable(_ name: String) -> String? {
        ProcessRunner.findExecutable(name)
    }

    func runVersionCommand(at path: String, arguments: [String]) async throws -> String? {
        let result = try await ProcessRunner.run(path, arguments: arguments)
        guard result.isSuccess else { return nil }
        return result.stdout
    }

    func fileExists(atPath: String) -> Bool {
        FileManager.default.fileExists(atPath: atPath)
    }

    func destinationOfSymbolicLink(atPath: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: atPath)
    }
}

// MARK: - ExternalToolHealth

/// Reports installation and version health for the external tools MLM
/// depends on for downloading and transcoding.
///
/// This type is **side-effect free**: it only probes versions, never
/// installs, upgrades, or mutates anything. The "latest known version"
/// is always supplied by the caller — this type never fetches it from
/// the network.
struct ExternalToolHealth: Sendable {

    /// Tools that MLM shells out to for downloading / transcoding.
    enum Tool: String, CaseIterable, Sendable {
        case ytdlp = "yt-dlp"
        case scdl
        case ffmpeg
        case ffprobe
    }

    let environment: ToolEnvironment

    init(environment: ToolEnvironment = LiveToolEnvironment()) {
        self.environment = environment
    }

    /// Check all tools at once. `latestVersions` maps each tool to its
    /// latest known version string; tools not present in the dictionary
    /// are reported as `.unknown` (installed but staleness indeterminate).
    func checkAll(latestVersions: [Tool: String]) async -> [ToolHealth] {
        var results: [ToolHealth] = []
        for tool in Tool.allCases {
            let report = await check(tool, latestVersion: latestVersions[tool])
            results.append(report)
        }
        return results
    }

    /// Check a single tool. Pass `nil` for `latestVersion` when no
    /// comparison target is available — the tool will be `.unknown`
    /// if installed.
    func check(_ tool: Tool, latestVersion: String?) async -> ToolHealth {
        let binaryName = tool.rawValue

        // 1. Resolve binary
        guard let path = environment.findExecutable(binaryName) else {
            return ToolHealth(
                name: binaryName,
                path: nil,
                installed: false,
                versionString: nil,
                parsedVersion: nil,
                status: .missing,
                latestKnownVersion: latestVersion,
                message: Self.missingMessage(for: tool),
                bundledYtDlp: nil
            )
        }

        // 2. Probe version
        let versionArgs = Self.versionArguments(for: tool)
        let output = try? await environment.runVersionCommand(at: path, arguments: versionArgs)
        let versionString = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedVersion = versionString.flatMap { ToolVersion($0) }

        // 3. For scdl, also probe the bundled yt-dlp inside the pipx venv
        var bundledYtDlp: BundledYtDlpHealth? = nil
        if tool == .scdl {
            bundledYtDlp = await checkBundledYtDlp(scdlPath: path, latestVersion: latestVersion)
        }

        // 4. Determine status and message
        if tool == .scdl {
            return buildScdlReport(
                path: path,
                versionString: versionString,
                parsedVersion: parsedVersion,
                latestVersion: latestVersion,
                bundledYtDlp: bundledYtDlp
            )
        } else {
            return buildStandardReport(
                tool: tool,
                path: path,
                versionString: versionString,
                parsedVersion: parsedVersion,
                latestVersion: latestVersion
            )
        }
    }

    // MARK: - Report builders

    private func buildStandardReport(
        tool: Tool,
        path: String,
        versionString: String?,
        parsedVersion: ToolVersion?,
        latestVersion: String?
    ) -> ToolHealth {
        let binaryName = tool.rawValue

        guard let parsed = parsedVersion else {
            return ToolHealth(
                name: binaryName,
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: nil,
                status: .unknown,
                latestKnownVersion: latestVersion,
                message: "\(binaryName) was found at \(path) but its version could not be determined.",
                bundledYtDlp: nil
            )
        }

        guard let latestStr = latestVersion, let latestParsed = ToolVersion(latestStr) else {
            return ToolHealth(
                name: binaryName,
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: parsed,
                status: .unknown,
                latestKnownVersion: latestVersion,
                message: "\(binaryName) \(parsed.raw) is installed but no latest version was provided for comparison.",
                bundledYtDlp: nil
            )
        }

        if parsed < latestParsed {
            return ToolHealth(
                name: binaryName,
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: parsed,
                status: .outdated,
                latestKnownVersion: latestVersion,
                message: Self.outdatedMessage(for: tool, installedVersion: parsed.raw, latestVersion: latestParsed.raw),
                bundledYtDlp: nil
            )
        } else {
            return ToolHealth(
                name: binaryName,
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: parsed,
                status: .ok,
                latestKnownVersion: latestVersion,
                message: "",
                bundledYtDlp: nil
            )
        }
    }

    private func buildScdlReport(
        path: String,
        versionString: String?,
        parsedVersion: ToolVersion?,
        latestVersion: String?,
        bundledYtDlp: BundledYtDlpHealth?
    ) -> ToolHealth {
        // scdl's status is driven by the bundled yt-dlp, because that
        // is the extractor scdl actually delegates to for SoundCloud.
        if let bundled = bundledYtDlp {
            let message: String
            switch bundled.status {
            case .outdated:
                message = bundled.message
            case .ok:
                message = ""
            case .unknown:
                message = "scdl is installed at \(path) but its bundled yt-dlp version could not be determined."
            case .missing:
                message = "scdl's bundled yt-dlp is missing."
            }
            return ToolHealth(
                name: "scdl",
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: parsedVersion,
                status: bundled.status,
                latestKnownVersion: latestVersion,
                message: message,
                bundledYtDlp: bundled
            )
        }

        // Could not discover bundled yt-dlp at all
        if parsedVersion == nil {
            return ToolHealth(
                name: "scdl",
                path: path,
                installed: true,
                versionString: versionString,
                parsedVersion: nil,
                status: .unknown,
                latestKnownVersion: latestVersion,
                message: "scdl was found at \(path) but its version could not be determined.",
                bundledYtDlp: nil
            )
        }

        return ToolHealth(
            name: "scdl",
            path: path,
            installed: true,
            versionString: versionString,
            parsedVersion: parsedVersion,
            status: .unknown,
            latestKnownVersion: latestVersion,
            message: "scdl \(versionString ?? "") is installed but its bundled yt-dlp version could not be determined.",
            bundledYtDlp: nil
        )
    }

    // MARK: - Bundled yt-dlp detection

    /// For pipx-installed scdl, the binary at `~/.local/bin/scdl` is a
    /// symlink into `~/.local/pipx/venvs/scdl/bin/scdl`. The same venv
    /// bundles its own `yt-dlp` at `…/venvs/scdl/bin/yt-dlp`. We resolve
    /// the symlink, look for `yt-dlp` in the same directory, and probe
    /// its version. If any step fails we return `nil` (honestly unknown).
    private func checkBundledYtDlp(scdlPath: String, latestVersion: String?) async -> BundledYtDlpHealth? {
        guard let resolved = environment.destinationOfSymbolicLink(atPath: scdlPath) else {
            return nil
        }

        let resolvedDir = (resolved as NSString).deletingLastPathComponent
        let bundledPath = (resolvedDir as NSString).appendingPathComponent("yt-dlp")

        guard environment.fileExists(atPath: bundledPath) else {
            return BundledYtDlpHealth(
                path: bundledPath,
                versionString: nil,
                parsedVersion: nil,
                status: .unknown,
                message: "scdl's bundled yt-dlp was not found."
            )
        }

        let output = try? await environment.runVersionCommand(at: bundledPath, arguments: ["--version"])
        let versionString = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedVersion = versionString.flatMap { ToolVersion($0) }
        let latestParsed = latestVersion.flatMap { ToolVersion($0) }

        guard let parsed = parsedVersion else {
            return BundledYtDlpHealth(
                path: bundledPath,
                versionString: versionString,
                parsedVersion: nil,
                status: .unknown,
                message: "scdl's bundled yt-dlp was found but its version could not be determined."
            )
        }

        guard let latest = latestParsed else {
            return BundledYtDlpHealth(
                path: bundledPath,
                versionString: versionString,
                parsedVersion: parsed,
                status: .unknown,
                message: "scdl's bundled yt-dlp (\(parsed.raw)) is installed but no latest version was provided."
            )
        }

        if parsed < latest {
            return BundledYtDlpHealth(
                path: bundledPath,
                versionString: versionString,
                parsedVersion: parsed,
                status: .outdated,
                message: "scdl's bundled yt-dlp (\(parsed.raw)) is outdated (latest: \(latest.raw)). Update with `pipx upgrade scdl` to update the extractor scdl actually uses."
            )
        } else {
            return BundledYtDlpHealth(
                path: bundledPath,
                versionString: versionString,
                parsedVersion: parsed,
                status: .ok,
                message: ""
            )
        }
    }

    // MARK: - Messages

    private static func versionArguments(for tool: Tool) -> [String] {
        switch tool {
        case .ytdlp, .scdl:
            return ["--version"]
        case .ffmpeg, .ffprobe:
            return ["-version"]
        }
    }

    private static func missingMessage(for tool: Tool) -> String {
        switch tool {
        case .ytdlp:
            return "yt-dlp is not installed. Install with `brew install yt-dlp`."
        case .scdl:
            return "scdl is not installed. Install with `pipx install scdl`."
        case .ffmpeg:
            return "ffmpeg is not installed. Install with `brew install ffmpeg`."
        case .ffprobe:
            return "ffprobe is not installed. Install with `brew install ffmpeg`."
        }
    }

    private static func outdatedMessage(for tool: Tool, installedVersion: String, latestVersion: String) -> String {
        switch tool {
        case .ytdlp:
            return "yt-dlp \(installedVersion) is outdated (latest: \(latestVersion)). Update with `brew upgrade yt-dlp` or `yt-dlp -U`."
        case .scdl:
            return "scdl \(installedVersion) is outdated (latest: \(latestVersion)). Update with `pipx upgrade scdl`."
        case .ffmpeg:
            return "ffmpeg \(installedVersion) is outdated (latest: \(latestVersion)). Update with `brew upgrade ffmpeg`."
        case .ffprobe:
            return "ffprobe \(installedVersion) is outdated (latest: \(latestVersion)). Update with `brew upgrade ffmpeg`."
        }
    }
}
