import SwiftUI

/// DisclosureGroup of failed sync tracks with aligned rows, per-row context
/// menu, and double-click-to-play + open-detail-inspector (D-13 / SYNC-v2-17).
///
/// Defaults to collapsed to avoid visual clutter when syncs partially fail.
/// Fetches full `Track` records on appear so the rows can show album info and
/// support Play / Play Next / Show in Finder actions.
struct SyncFailedDisclosure: View {
    let failedTracks: [SyncService.SyncFailure]
    let vm: SyncViewModel

    @Environment(\.container) private var container
    @State private var isExpanded: Bool = false
    @State private var tracksByID: [Int64: Track] = [:]
    @State private var hoveredID: Int64?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                ForEach(failedTracks.indices, id: \.self) { i in
                    row(failedTracks[i])
                    if i < failedTracks.count - 1 {
                        Divider().background(Color.mlmEdge.opacity(0.4))
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmError)
                    .font(.system(size: 12))
                Text("Failed tracks (\(failedTracks.count))")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .task {
            await loadTracks()
        }
    }

    // MARK: - Data loading

    private func loadTracks() async {
        let ids = Set(failedTracks.map(\.trackId))
        guard !ids.isEmpty, let repo = container.trackRepository else { return }
        do {
            let tracks = try await repo.fetchTracks(ids: ids)
            await MainActor.run {
                var map: [Int64: Track] = [:]
                for t in tracks {
                    if let id = t.id { map[id] = t }
                }
                tracksByID = map
            }
        } catch {
            AppLogger.shared.log(
                "SyncFailedDisclosure: failed to load tracks: \(error.localizedDescription)",
                level: .error,
                source: "SyncFailedDisclosure"
            )
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ failure: SyncService.SyncFailure) -> some View {
        let track = tracksByID[failure.trackId]
        let title = track?.title ?? failure.title
        let artist = [track?.artist, failure.artist]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let album = track?.album

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.mlmError)
                .font(.system(size: 12))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(failure.reason)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                        .lineLimit(1)
                    if let album, !album.isEmpty {
                        Text("·")
                            .foregroundColor(.mlmInkMuted)
                        Text(album)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Button("Retry") {
                Task { await vm.retryFailedTrack(failure.trackId) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(hoveredID == failure.trackId ? Color.mlmBase.opacity(0.6) : Color.clear)
        .onHover { hovering in
            hoveredID = hovering ? failure.trackId : (hoveredID == failure.trackId ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            openDetail(failure.trackId, play: true)
        }
        .contextMenu {
            rowMenu(failure, track: track)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowMenu(_ failure: SyncService.SyncFailure, track: Track?) -> some View {
        Button {
            openDetail(failure.trackId, play: true)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(track == nil || track?.isLocal == false)

        Button {
            // The shared Play Next: confirmation with Undo, only tracks with a file (W2-D).
            if let track {
                TrackCommandActions.playNext([track], container: container)
            }
        } label: {
            Label("Play Next", systemImage: "forward.end.fill")
        }
        .disabled(track == nil)

        Divider()

        Button {
            openDetail(failure.trackId, play: false)
        } label: {
            Label("Show Details", systemImage: "info.circle")
        }

        Button {
            Task { await vm.retryFailedTrack(failure.trackId) }
        } label: {
            Label("Retry Sync", systemImage: "arrow.clockwise")
        }

        Divider()

        Button {
            Task { await revealInFinder(failure.trackId) }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(track == nil)

        Button {
            Task { await copyFilePath(failure.trackId) }
        } label: {
            Label("Copy File Path", systemImage: "doc.on.doc")
        }
        .disabled(track == nil)
    }

    // MARK: - Actions

    private func openDetail(_ trackId: Int64, play: Bool) {
        NotificationCenter.default.post(
            name: .openTrackDetailForTrack,
            object: nil,
            userInfo: ["trackId": trackId, "play": play]
        )
    }

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

    private func revealInFinder(_ trackId: Int64) async {
        guard let track = tracksByID[trackId],
              let url = await resolveLocalURL(for: track) else { return }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Copy the resolved absolute path of a track.
    /// Paths containing whitespace are wrapped in double quotes so the value
    /// can be pasted directly into a terminal.
    private func copyFilePath(_ trackId: Int64) async {
        guard let track = tracksByID[trackId],
              let url = await resolveLocalURL(for: track) else { return }
        let raw = url.path
        let pasteValue = raw.rangeOfCharacter(from: .whitespaces) != nil
            ? "\"\(raw)\""
            : raw
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pasteValue, forType: .string)
        }
    }
}
