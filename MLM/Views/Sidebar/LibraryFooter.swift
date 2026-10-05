import AppKit
import SwiftUI

/// Sidebar footer (P-LIBFOOTER, UC-SIDE-10, DEC-031): names the open library, says the drive
/// state in two words, and is the library switcher. Fixes PP-SHELL-07 (the open library had
/// no name anywhere).
///
/// Uses the same coordinator calls as File ▸ New Library… / Open Library… / Open Recent
/// (`LibraryCommands`).
struct LibraryFooter: View {
    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings

    private var launch: LibraryLaunchCoordinator { LibraryLaunchCoordinator.shared }

    var body: some View {
        let name = Self.libraryName(launch)
        let detail = secondLine
        Menu {
            Section("Open Recent") {
                Toggle(name, isOn: .constant(true))
                ForEach(launch.recentLibraries) { recent in
                    Button(Self.recentTitle(recent)) {
                        Task { await launch.handleOpen(recent.entry.url) }
                    }
                    .disabled(recent.availability != .available)
                }
            }
            Divider()
            Button("Open Library…") {
                if let url = LibraryFilePanel.chooseLibraryFile() {
                    Task { await launch.handleOpen(url) }
                }
            }
            Button("New Library…") {
                launch.requestNewLibrary()
            }
            Divider()
            Button("Show Library File in Finder") {
                if let url = launch.activePackageURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(launch.activePackageURL == nil)
            Button("Library Settings…") {
                openSettings(tab: .library)
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "music.note.house")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .help(helpText(name: name))
        .accessibilityLabel("Library \(name)")
        .accessibilityValue(detail ?? "")
    }

    /// `12,935 tracks`, or `“Lexxar” — not connected` while the disk is away.
    private var secondLine: String? {
        let drive = LibraryDriveState.current(container)
        if drive.isOffline, let volume = drive.volumeName {
            return LibraryDriveState.footerText(volume)
        }
        guard let library = container.libraryViewModel else { return nil }
        return StatusBarText.tracks(library.libraryTrackCount)
    }

    private func helpText(name: String) -> String {
        if let path = launch.activePackageURL?.path {
            return "\(name)\n\(path)"
        }
        return name
    }

    // MARK: - Shared wording

    /// The open library's name (UC-WIN-06, §15.1 “always named”). A pre-library-file
    /// install has no name yet and reads `MLM` until it is set up.
    @MainActor
    static func libraryName(_ launch: LibraryLaunchCoordinator) -> String {
        if let name = launch.activeLibraryName, !name.isEmpty { return name }
        if let url = launch.activePackageURL { return url.deletingPathExtension().lastPathComponent }
        return "MLM"
    }

    /// Open Recent title with the state suffix (`— Not connected`, `— Not found`).
    static func recentTitle(_ recent: LibraryLaunchCoordinator.RecentLibrary) -> String {
        let name = recent.entry.displayName
        switch recent.availability {
        case .available: return name
        case .notFound: return name + " — Not found"
        case .notConnected: return name + " — Not connected"
        }
    }
}
