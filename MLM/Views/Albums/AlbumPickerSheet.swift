import SwiftUI

/// The album picker (W4-2b, IMP-094): a search field and the albums that can be chosen, the best
/// fit first (`AlbumPickRanking`), one selection. Embedded in Merge with Another Album and, as
/// `AlbumPickerSheet`, in Review ▸ Albums' `Choose Another Album…`.
struct AlbumPicker: View {
    let reference: AlbumPickReference
    /// The album whose group is left out (the one being merged); nil for Review.
    var excludingGroupOf: Int64?
    /// Select the first album when it is the same album (same album artist and title).
    var preselectsSameAlbum = false
    @Binding var query: String
    @Binding var selection: AlbumCandidate?
    var minHeight: CGFloat = 150

    @Environment(\.container) private var container
    @State private var candidates: [AlbumCandidate] = []
    @State private var isLoaded = false

    private var ranked: [AlbumCandidate] {
        AlbumPickRanking.rank(candidates, for: reference, query: query)
    }

    private var selectedID: Binding<Int64?> {
        Binding(
            get: { selection?.id },
            set: { id in selection = id.flatMap { id in candidates.first { $0.id == id } } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField("Search albums", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search albums")
            List(ranked, selection: selectedID) { candidate in
                row(candidate)
            }
            .listStyle(.bordered)
            .frame(minHeight: minHeight)
            .overlay {
                if isLoaded, ranked.isEmpty {
                    Text(candidates.isEmpty ? "No other album is in the library." : "No album matches the search.")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("album_picker")
        }
        .task {
            guard let repository = container.albumRepository else {
                isLoaded = true
                return
            }
            candidates = (try? await repository.pickCandidates(excludingGroupOf: excludingGroupOf)) ?? []
            isLoaded = true
            if preselectsSameAlbum, selection == nil, let first = ranked.first,
               AlbumPickRanking.tier(of: first.album, for: reference) == .sameKey {
                selection = first
            }
        }
        .onChange(of: query) { _, _ in
            if let selection, !ranked.contains(where: { $0.id == selection.id }) { self.selection = nil }
        }
    }

    private func row(_ candidate: AlbumCandidate) -> some View {
        HStack(spacing: Spacing.m) {
            AlbumCoverView(request: AlbumCoverRequest(albumID: candidate.id, coverPath: candidate.album.coverPath, firstTrackID: nil), cornerRadius: 4)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(candidate.album.title).lineLimit(1)
                Text(candidate.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .tag(candidate.id)
        .accessibilityElement(children: .combine)
    }
}

/// **Choose Another Album…** in Review ▸ Albums (V-REV.N11): for a row whose suggestion is `No
/// Match`, or whose other suggestions are used up. Choosing replaces the row's suggestion; nothing
/// is written until Accept.
struct AlbumPickerSheet: View {
    /// The track's title, for the sheet's title.
    let trackTitle: String
    let reference: AlbumPickReference
    let choose: (Album) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: AlbumCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(Self.title(trackTitle))
                .font(.headline)
            Text("The chosen album becomes the suggestion for this track. Nothing changes until you accept it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AlbumPicker(reference: reference, query: $query, selection: $selection)
            HStack {
                Text("You can still reject the suggestion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let album = selection?.album {
                        choose(album)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(Spacing.l)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 380)
    }

    static func title(_ track: String) -> String { "Choose an Album for “\(track)”" }
}
