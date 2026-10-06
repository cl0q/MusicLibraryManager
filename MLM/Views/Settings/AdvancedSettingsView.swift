import AppKit
import SwiftUI

/// Settings ▸ Advanced (ST-ADVANCED, DEC-025, DEC-035): the credentials file (where it is and
/// whether it was found — never its contents), diagnostics, the list cache (moved from
/// Maintenance, ST-MAINT.E04–E06) and — until W3-GEN builds the Genres destination — the genre
/// tools under their interim label, so they stay reachable.
///
/// Not built: `Log detail` (MLM has no log-level setting to switch) and `Reset Tips` (no TipKit
/// tips exist yet — W5-2).
struct AdvancedSettingsView: View {
    @Environment(\.container) private var container
    @State private var credentialsFound = true
    @State private var copiedSummary = false

    var body: some View {
        NavigationStack {
            Form {
                genresSection
                credentialsSection
                diagnosticsSection
                listsSection
            }
            .formStyle(.grouped)
            .navigationDestination(for: AdvancedDestination.self) { _ in
                GrooveStudioView()
                    .navigationTitle("Genres")
            }
        }
        .onAppear(perform: checkCredentials)
    }

    private enum AdvancedDestination: Hashable { case genreTools }

    // MARK: Genres (interim until W3-GEN)

    private var genresSection: some View {
        Section {
            NavigationLink(value: AdvancedDestination.genreTools) {
                SettingsRowLabel("Genres") {
                    Text("These genre tools move to Genres in the main window’s sidebar.")
                }
            }
            .disabled(!container.isInitialized)
        }
    }

    // MARK: Credentials file

    private var credentialsSection: some View {
        Section {
            LabeledContent {
                HStack {
                    ShowInFinderButton(url: CredentialsLoader.envFilePath)
                    Button("Check Again", action: checkCredentials)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsPath(CredentialsLoader.envFilePath)
                    Group {
                        if credentialsFound {
                            HStack(spacing: 4) {
                                SettingsState(text: "Found", systemImage: "checkmark.circle", tone: .ok)
                                Text("· contains the app keys for SoundCloud and Spotify")
                            }
                        } else {
                            HStack(spacing: 4) {
                                SettingsState(text: "Not found", systemImage: "questionmark.folder", tone: .error)
                                Text("· put the file at this location, then press Check Again")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Credentials file")
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("MLM reads the keys it needs and never shows the contents. The file is not part of any library file or backup. Values set in it take precedence over fields in Settings.")
        }
    }

    private func checkCredentials() {
        // Existence only — the contents are never read here.
        credentialsFound = FileManager.default.fileExists(atPath: CredentialsLoader.envFilePath.path)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Logs") {
                HStack {
                    Button("Open Activity ▸ Logs") { ActivityWindowOpener.open(tab: .logs) }
                    ShowInFinderButton(url: AppLogger.shared.logFileURL)
                }
            }
            LabeledContent {
                Button(copiedSummary ? "Copied" : "Copy") { copySummary() }
            } label: {
                SettingsRowLabel("Diagnostic summary") {
                    Text("Versions, tool locations and library counts — no titles, no credentials.")
                }
            }
        }
    }

    private func copySummary() {
        Task {
            await DownloadToolsModel.shared.check()
            let tracks = try? await container.trackRepository?.countLocalTracks()
            let text = Self.diagnosticSummary(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                system: ProcessInfo.processInfo.operatingSystemVersionString,
                tools: DownloadToolsModel.shared.rows,
                libraryName: LibraryLaunchCoordinator.shared.activeLibraryName,
                tracksWithFile: tracks)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedSummary = true
            try? await Task.sleep(for: .seconds(2))
            copiedSummary = false
        }
    }

    /// The copied text: no track titles, no paths below the home folder's music, no credentials.
    static func diagnosticSummary(appVersion: String?, system: String, tools: [DownloadToolRow],
                                  libraryName: String?, tracksWithFile: Int?) -> String {
        var lines = ["MLM \(appVersion ?? "development build")", "macOS \(system)"]
        for tool in tools {
            lines.append(tool.isFound
                         ? "\(tool.name): \(tool.version ?? "version unknown") at \(tool.path ?? "?")"
                         : "\(tool.name): not found")
        }
        if libraryName != nil {
            lines.append("Library open: yes · \(tracksWithFile.map { "\($0) tracks with a file" } ?? "track count unknown")")
        } else {
            lines.append("Library open: no")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Lists (moved from Maintenance)

    private var listsSection: some View {
        Section("Lists") {
            let cache = container.playlistTableCache
            let summaries = cache?.summaries ?? []
            let cap = cache?.cap ?? PlaylistTableCache.defaultCap
            LabeledContent {
                Stepper(value: Binding(
                    get: { cap },
                    set: { cache?.cap = $0 }
                ), in: PlaylistTableCache.validCapRange) {
                    Text("\(cap)").monospacedDigit()
                }
            } label: {
                SettingsRowLabel("Keep recently opened playlists ready") {
                    Text(Self.listCacheLine(libraryRows: container.libraryViewModel?.displayedTracks.count ?? 0,
                                            playlists: summaries.map(\.name),
                                            playlistRows: summaries.map(\.trackCount).reduce(0, +)))
                }
            }
            .disabled(cache == nil)
        }
    }

    /// `Makes reopening instant. In use now: about 26 MB — All Tracks and 3 playlists (Warm-up, …).`
    /// 0 turns it off.
    static func listCacheLine(libraryRows: Int, playlists: [String], playlistRows: Int) -> String {
        let bytes = Int64((libraryRows + playlistRows) * PlaylistTableCache.estimatedBytesPerTrack)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
        var text = "Makes reopening instant; 0 turns it off. In use now: about \(size) — All Tracks"
        if !playlists.isEmpty {
            let names = playlists.prefix(3).joined(separator: ", ") + (playlists.count > 3 ? ", …" : "")
            text += " and \(playlists.count == 1 ? "1 playlist" : "\(playlists.count) playlists") (\(names))"
        }
        return text + "."
    }
}
