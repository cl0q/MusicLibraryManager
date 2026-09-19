import SwiftUI

/// Lazy ffmpeg/ffprobe diagnostics tab for the track detail inspector.
///
/// Constructed only when the Debug tab is selected (MetadataPanel's `switch`
/// branch), so the `.task` modifier fires exactly once per tab activation.
/// Resolves the local file, runs the two-pass probe+decode, and renders the
/// result in three cards: decode check, stream info, and decoder log.
struct DebugTabView: View {
    let track: Track

    @Environment(\.container) private var container

    @State private var diagnostics: TrackDiagnosticsService.TrackDiagnostics?
    @State private var isLoading = false
    @State private var hasRun = false
    @State private var missingLocalFile = false
    @State private var ffmpegMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                loadingCard
            } else if missingLocalFile {
                missingFileCard
            } else if ffmpegMissing {
                ffmpegMissingCard
            } else if let diag = diagnostics {
                decodeCheckCard(diag)
                streamInfoCard(diag)
                decoderLogCard(diag)
                footerLine(diag)
            }
        }
        .task {
            await run()
        }
    }

    // MARK: - Runner

    private func run() async {
        guard !isLoading && !hasRun else { return }
        isLoading = true
        defer { isLoading = false }

        guard let url = await resolveLocalURL(for: track) else {
            missingLocalFile = true
            hasRun = true
            return
        }

        let result = await TrackDiagnosticsService.diagnose(fileURL: url)
        if let result {
            diagnostics = result
        } else {
            ffmpegMissing = true
        }
        hasRun = true
    }

    // MARK: - Cards

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Decoding full file with ffmpeg…")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
            Spacer()
        }
        .padding(12)
        .background(cardBackground)
    }

    private var missingFileCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No local file", systemImage: "arrow.down.circle")
                .font(MLMFont.bodyBold)
                .foregroundColor(.mlmInk)
            Text("Download the track to run ffmpeg diagnostics.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var ffmpegMissingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("ffmpeg not found", systemImage: "exclamationmark.triangle")
                .font(MLMFont.bodyBold)
                .foregroundColor(.mlmInk)
            Text("Install ffmpeg in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, or /usr/bin to enable diagnostics.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private func decodeCheckCard(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> some View {
        VStack(spacing: 8) {
            fileRow("Decode errors", value: "\(diag.errorCount)",
                    valueColor: diag.errorCount > 0 ? .mlmError : .mlmSuccess)
            fileRow("Warnings", value: "\(diag.warningCount)",
                    valueColor: diag.warningCount > 0 ? .mlmError : .mlmSuccess)
            fileRow("Broken frames", value: "\(diag.brokenFrameCount)",
                    valueColor: diag.brokenFrameCount > 0 ? .mlmError : .mlmSuccess)
            fileRow("ffmpeg exit code", value: "\(diag.decodeExitCode)",
                    valueColor: diag.decodeExitCode == 0 ? .mlmSuccess : .mlmError)
        }
        .padding(12)
        .background(cardBackground)
    }

    private func streamInfoCard(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> some View {
        VStack(spacing: 8) {
            fileRow("Container", value: diag.containerFormat ?? "—")
            fileRow("Codec", value: diag.codecName ?? "—")
            fileRow("Sample rate", value: diag.sampleRateHz.map { "\($0) Hz" } ?? "—")
            fileRow("Channels", value: channelsText(diag))
            fileRow("Bitrate", value: diag.bitrateKbps.map { "\($0) kbps" } ?? "—")
            fileRow("Duration", value: durationText(diag))
        }
        .padding(12)
        .background(cardBackground)
    }

    private func decoderLogCard(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Decoder log", systemImage: "terminal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.mlmInk)
                Spacer()
                Button {
                    copyLog(diag)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task {
                        hasRun = false
                        diagnostics = nil
                        missingLocalFile = false
                        ffmpegMissing = false
                        await run()
                    }
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let allLines = diag.errorLines + diag.warningLines
            if allLines.isEmpty {
                Text("No decode errors reported — the file decodes cleanly.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmSuccess)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    Text(allLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.mlmInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func footerLine(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return Text("ffmpeg: \(diag.ffmpegPath) · ran \(formatter.string(from: diag.ranAt))")
            .font(MLMFont.dataSmall)
            .foregroundColor(.mlmInkMuted)
    }

    // MARK: - Helpers

    private func channelsText(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> String {
        guard let ch = diag.channels else { return "—" }
        if let layout = diag.channelLayout, !layout.isEmpty {
            return "\(ch) (\(layout))"
        }
        return "\(ch)"
    }

    private func durationText(_ diag: TrackDiagnosticsService.TrackDiagnostics) -> String {
        if let secs = diag.durationSeconds {
            let minutes = Int(secs) / 60
            let seconds = Int(secs) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        return track.formattedDuration
    }

    private func fileRow(_ label: String, value: String, valueColor: Color = .mlmInk) -> some View {
        HStack {
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(MLMFont.body)
                .foregroundColor(valueColor)
            Spacer()
        }
    }

    private func copyLog(_ diag: TrackDiagnosticsService.TrackDiagnostics) {
        let allLines = diag.errorLines + diag.warningLines
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allLines.joined(separator: "\n"), forType: .string)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.mlmSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - File resolution

    private func resolveLocalURL(for track: Track) async -> URL? {
        let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }
}
