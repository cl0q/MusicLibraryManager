import SwiftUI

/// **Use a Track from the Library…** (CM-ALBD-ABSENT, IMP-095): the library's tracks that are not
/// on this album, searched in place, one chosen to take the place of a `Track ‹n›` gap. `Use`
/// adds it to the album with that disc and number — one undo step; the track's own tags are not
/// changed.
struct AlbumTrackPickerSheet: View {
    let albumID: Int64
    let albumTitle: String
    let disc: Int
    let number: Int
    let hasDiscs: Bool

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellActions.self) private var shell: ShellActions?

    @State private var text = ""
    @State private var tracks: [PickRow] = []
    @State private var selection: Int64?
    @State private var isLoaded = false
    @State private var isUsing = false
    @State private var failure: String?

    private struct PickRow: Identifiable {
        let track: Track
        var id: Int64 { track.id ?? 0 }
    }

    private var chosen: Track? { tracks.first { $0.id == selection }?.track }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(AlbumPlacement.title).font(.headline)
            Text(AlbumPlacement.sentence(album: albumTitle, disc: disc, number: number, hasDiscs: hasDiscs))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(AlbumPlacement.searchPrompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AlbumPlacement.searchPrompt)
            Table(tracks, selection: $selection) {
                TableColumn("Title") { row in Text(row.track.title).lineLimit(1) }
                    .width(min: 140, ideal: 220)
                TableColumn("Artist") { row in Text(row.track.artist).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 100, ideal: 150)
                TableColumn("Album") { row in
                    Text(TrackMetadataPresentation.isRealAlbum(row.track.album) ? row.track.album : "—").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 150)
                TableColumn("Time") { row in
                    Text(TrackDurationText.trackTime(row.track.duration) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 60, max: 70)
            }
            .frame(minHeight: 220)
            .overlay {
                if isLoaded, tracks.isEmpty {
                    Text(AlbumPlacement.nothingFound).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("album_track_picker")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(AlbumPlacement.footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AlbumPlacement.button) { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil || isUsing)
            }
        }
        .padding(Spacing.l)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440)
        .task(id: text) { await search() }
    }

    private func search() async {
        guard let manager = container.databaseManager else {
            isLoaded = true
            return
        }
        let repository = AlbumTrackRepository(database: manager.pool)
        tracks = ((try? await repository.libraryTracks(notOn: albumID, matching: SearchFilter(text: text))) ?? []).map(PickRow.init)
        isLoaded = true
        if let selection, !tracks.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func use() {
        guard let track = chosen, let id = track.id, let edits = shell?.edits else { return }
        isUsing = true
        failure = nil
        let title = track.title
        Task {
            do {
                try await edits.useTrack(id, inAlbum: albumID, disc: disc, number: number)
                dismiss()
            } catch {
                failure = AlbumPlacement.couldntUse(title)
                isUsing = false
            }
        }
    }
}
