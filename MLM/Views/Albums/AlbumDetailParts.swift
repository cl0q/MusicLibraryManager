import SwiftUI

// The album page's parts (V-ALBD, W4-2): header, status line, Edit Order bar, the track area
// with Other versions. Driven by an `AlbumDetailModel` and plain closures — the page
// (`AlbumDetailView`) wires them to the shell; a snapshot fixture wires none.

/// What the parts do. Defaults do nothing (fixtures).
struct AlbumDetailCallbacks {
    var openArtist: (String) -> Void = { _ in }
    var play: (_ shuffled: Bool) -> Void = { _ in }
    var chooseEdition: (AlbumEditionInfo) -> Void = { _ in }
    var downloadMissing: () -> Void = {}
    var cancelEditing: () -> Void = {}
    var finishEditing: () -> Void = {}
}

// MARK: - Header (UC-LAYOUT-06)

/// Cover (160 pt, extends under the sidebar), kind line, title, album artist as a link, facts
/// line with the edition picker, `Play` · `Shuffle` · `More`. The title is not editable here —
/// `Edit Album Info…` edits it with the other fields (V-ALBD.N04).
struct AlbumDetailHeader<Cover: View, More: View>: View {
    let model: AlbumDetailModel
    /// Why Play and Shuffle are disabled, or nil.
    var playReason: String?
    /// The line beside the buttons while the library's drive is away (V-ALBD.N25).
    var offlineLine: String?
    let callbacks: AlbumDetailCallbacks
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let more: () -> More

    var body: some View {
        let album = model.album
        HStack(alignment: .bottom, spacing: Spacing.l) {
            cover()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(AlbumText.kindLabel(isCompilation: model.isCompilation))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(album?.title ?? "")
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                artist(album)
                HStack(spacing: Spacing.m) {
                    Text(model.factsLine)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    editionPicker
                }
                buttons
                    .padding(.top, Spacing.s)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .background(.background)
    }

    /// The album artist: a `Go to Artist` link; plain text for a compilation (V-ALBD.N05).
    @ViewBuilder
    private func artist(_ album: Album?) -> some View {
        if let album {
            if let link = AlbumMenuModel.artistLink(albumArtist: album.albumArtist, isCompilation: model.isCompilation) {
                Button(link) { callbacks.openArtist(link) }
                    .buttonStyle(.link)
                    .help("Go to Artist")
            } else {
                Text(album.albumArtist).foregroundStyle(.secondary)
            }
        }
    }

    /// Only when the album has more than one edition: each line says how much of it is in the
    /// library; the check mark is the preferred edition (V-ALBD.N07/N08).
    @ViewBuilder
    private var editionPicker: some View {
        if model.editions.count > 1 {
            let shown = model.editions.first { $0.id == model.album?.id }
            Menu {
                Section("Editions — the checked one is preferred") {
                    ForEach(model.editions) { edition in
                        Toggle(edition.line, isOn: Binding(get: { edition.isPreferred }, set: { _ in callbacks.chooseEdition(edition) }))
                    }
                }
            } label: {
                Text(shown?.name ?? "Edition")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Choose the edition")
        }
    }

    private var buttons: some View {
        let title = model.album?.title ?? "this album"
        return HStack(spacing: Spacing.s) {
            Button { callbacks.play(false) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(playReason != nil)
                .help(playReason ?? "Play “\(title)”")
            Button { callbacks.play(true) } label: { Label("Shuffle", systemImage: "shuffle") }
                .disabled(playReason != nil)
                .help(playReason ?? "Shuffle “\(title)”")
            Menu { more() } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            if let offlineLine {
                Text(offlineLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let playReason {
                Text(playReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Status line (IMP-076, V-ALBD.N13)

/// One sentence at album level when the album isn't complete — how much of the tracklist is not
/// in the library, not downloaded or failed — with the one batch action.
struct AlbumStatusLineView: View {
    let line: AlbumStatusLine
    var downloadMissing: () -> Void = {}

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(line.text).fontWeight(.semibold).monospacedDigit()
            Spacer(minLength: Spacing.s)
            if line.downloadCount > 0 {
                Button(line.downloadTitle, action: downloadMissing)
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Edit Order (IMP-081, V-ALBD.N23)

struct AlbumEditOrderBar: View {
    var cancel: () -> Void = {}
    var done: () -> Void = {}

    static let text = "Drag rows to reorder. Tracks are renumbered 1, 2, 3… within each disc. Files are not renamed."

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(Text("Edit Order.").fontWeight(.semibold)) \(Self.text)")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .background {
            ZStack {
                Rectangle().fill(.background)
                Rectangle().fill(.quaternary)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Other versions (V-ALBD.N22)

struct AlbumShelf: View {
    let editions: [AlbumEditionInfo]
    let covers: (AlbumEditionInfo) -> AlbumCoverRequest
    var show: (AlbumEditionInfo) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Other versions")
                .font(.headline)
                .padding(.horizontal, Spacing.xl)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.l) {
                    ForEach(editions) { edition in
                        Button { show(edition) } label: {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                AlbumCoverView(request: covers(edition))
                                    .frame(width: 120, height: 120)
                                Text(edition.name).fontWeight(.semibold).lineLimit(1)
                                Text(AlbumText.shelfLine(year: edition.album.year, inLibrary: edition.stat.inLibrary, total: edition.stat.total))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                Text(edition.isPreferred ? "Preferred edition" : " ")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 120, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(edition.line)
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - The page without its scaffold

/// What goes above the table: header, status line or Edit Order bar.
struct AlbumDetailTop<Cover: View, More: View>: View {
    let model: AlbumDetailModel
    var playReason: String?
    var offlineLine: String?
    let callbacks: AlbumDetailCallbacks
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let more: () -> More

    var body: some View {
        VStack(spacing: 0) {
            AlbumDetailHeader(model: model, playReason: playReason, offlineLine: offlineLine, callbacks: callbacks,
                              cover: cover, more: more)
            if model.isEditingOrder {
                AlbumEditOrderBar(cancel: callbacks.cancelEditing, done: callbacks.finishEditing)
            } else if let line = model.statusLine {
                AlbumStatusLineView(line: line, downloadMissing: callbacks.downloadMissing)
            }
        }
    }
}

/// The track table in the album's fixed order, with Other versions under it.
struct AlbumDetailTableArea: View {
    let model: AlbumDetailModel
    let configuration: TrackListConfiguration
    var callbacks = AlbumDetailCallbacks()

    var body: some View {
        VStack(spacing: 0) {
            TrackListTable(model: model.list, configuration: configuration) {
                emptyState
            }
            if !model.isEditingOrder, model.editions.count > 1 {
                AlbumShelf(
                    editions: model.editions.filter { $0.id != model.album?.id },
                    covers: { AlbumCoverRequest(albumID: $0.id, coverPath: $0.album.coverPath, firstTrackID: nil) },
                    show: callbacks.chooseEdition
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.filter.isEmpty {
            ContentUnavailableView {
                Label("No tracks in “\(model.album?.title ?? "this album")”", systemImage: "square.stack")
            } description: {
                Text("No track of this album is in the library any more.")
            }
        } else {
            ContentUnavailableView {
                Label("No tracks match", systemImage: "magnifyingglass")
            } description: {
                Text("No track of this album matches the search.")
            }
        }
    }
}
