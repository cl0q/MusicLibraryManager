import AppKit
import SwiftUI

// The Albums grid's building blocks (V-ALB, W4-2): cover, card, grid, empty state, first-load
// placeholders. Presentation only — no navigation, no database; the page (`AlbumsView`) adds the
// gestures, menus and drops. Opaque content, never glass (UC-GLASS-07); semantic colours only.

/// An album's picture: its cover file, else the first track's embedded artwork, else the neutral
/// placeholder — `square.stack` in `.tertiary` on `.quaternary`, never a coloured tile (IMP-078,
/// UC-COLOR). Loads lazily and cached (`AlbumCoverLoader`).
struct AlbumCoverView: View {
    let request: AlbumCoverRequest
    var cornerRadius: CGFloat = 7

    @State private var image: NSImage?
    @Environment(\.container) private var container
    @Environment(\.trackArtworkLoadingEnabled) private var loadingEnabled

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "square.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: request.cacheKey) {
            guard loadingEnabled else { return }
            let loader = AlbumCoverLoader.shared
            // A cached picture shows at once; a changed request never keeps the old one.
            image = loader.cached(request)
            guard image == nil, !loader.isKnownMiss(request) else { return }
            image = await loader.image(for: request, container: container)
        }
    }
}

/// A card of the grid (V-ALB.N05): cover, title, album artist and one line of facts — year and
/// track count, or `Incomplete · 9 of 12` in words. No badges, no colour codes.
struct AlbumCard: View {
    let listing: AlbumListing
    let cover: AlbumCoverRequest
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            AlbumCoverView(request: cover)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
            Text(listing.album.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(listing.album.title)
            Text(listing.album.albumArtist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(listing.album.albumArtist)
            Text(AlbumText.cardLine(listing))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listing.album.title), \(listing.album.albumArtist), \(AlbumText.cardLine(listing))")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The grid: `GridItem(.adaptive(minimum: 150))` cards in a lazy grid inside the page's scroll
/// view (UC-KIT-04).
struct AlbumGrid<Card: View>: View {
    let listings: [AlbumListing]
    @ViewBuilder let card: (AlbumListing) -> Card

    static var minimumWidth: CGFloat { 150 }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.l, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.l) {
            ForEach(listings) { listing in
                card(listing).id(listing.id)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First load only: placeholder cards under the real scope bar (V-ALB.N12, UC-EMPTY-04).
struct AlbumsPlaceholderGrid: View {
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.l, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.l) {
                ForEach(0..<18, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                        Text("Album title")
                        Text("Album artist").font(.subheadline)
                        Text("2000 · 00 tracks").font(.subheadline)
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .padding(Spacing.xl)
        }
        .accessibilityLabel("Loading albums")
    }
}

/// No albums at all (V-ALB.N11): one sentence and the way forward.
struct AlbumsEmptyContent: View {
    let noAlbumCount: Int
    /// `Find Albums…` — disabled with its reason until Review ▸ Albums exists (W4-3).
    var findAlbumsReason: String?
    var findAlbums: () -> Void = {}
    var importFiles: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label("No albums yet", systemImage: "square.stack")
        } description: {
            Text(AlbumText.emptyDescription(noAlbumCount: noAlbumCount))
        } actions: {
            Button("Find Albums…", action: findAlbums)
                .buttonStyle(.borderedProminent)
                .disabled(findAlbumsReason != nil)
                .help(findAlbumsReason ?? "")
            Button("Import Files or Folder…", action: importFiles)
        }
    }
}
