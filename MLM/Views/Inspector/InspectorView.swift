import SwiftUI

/// The tabs of Info (P-INSPECTOR.E09): a system segmented control, remembered per window.
enum InspectorTab: String, CaseIterable, Identifiable {
    case details
    case audio
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .audio: "Audio"
        case .file: "File"
        }
    }
}

/// Info, the trailing column's first mode (P-INSPECTOR, DEC-007, UC-TRAIL-01…04): follows the
/// **selection** of the last track list (`InspectedTrackSelection`), never the playing track,
/// and never opens itself. One track: its form; several: the same form with `Mixed`, edits
/// apply to all as one undo step; none: `No selection`.
struct InspectorView: View {
    /// Selected track ids in display order.
    let selection: [Int64]

    @Environment(\.container) private var container
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @State private var model: InspectorModel?

    /// `InspectedTrackSelection` source of the reset when another library opens.
    static let libraryChangeKey = "libraryChange"
    @SceneStorage("inspector.tab") private var tab: InspectorTab = .details

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            let model = self.model ?? InspectorModel(dependencies: .live(undo: undo, statusBar: statusBar))
            self.model = model
            model.select(selection)
        }
        .onChange(of: selection) { _, ids in model?.select(ids) }
        .onChange(of: container.activeLibrary?.libraryId) { _, _ in
            // Another library: its track ids mean other tracks (S4).
            model?.reset()
            InfoTrackRequest.shared.clear()
            InspectedTrackSelection.shared.update([], from: Self.libraryChangeKey)
        }
        .onDisappear { model?.commitAll() }
        // Rows changed elsewhere (another edit, a download, a file check): show the stored values.
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in model?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in model?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in model?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in model?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .downloadStateDidChange)) { _ in model?.reload() }
    }

    @ViewBuilder
    private func content(_ model: InspectorModel) -> some View {
        if model.isEmpty {
            ContentUnavailableView(
                "No selection",
                systemImage: "info.circle",
                description: Text("Select a track to see and edit its details.")
            )
        } else if let loadError = model.loadError {
            ContentUnavailableView {
                Label("Couldn’t show the selection", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else {
            VStack(spacing: 0) {
                InspectorHeader(tracks: model.tracks, count: model.trackIDs.count)
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.m)
                    .padding(.bottom, Spacing.s)
                Picker("Info", selection: $tab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xs)

                switch tab {
                case .details:
                    InspectorDetailsTab(model: model)
                case .audio:
                    InspectorAudioTab(tracks: model.tracks)
                case .file:
                    InspectorFileTab(tracks: model.tracks)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Header

/// Cover, title, artist and the format line (P-INSPECTOR.E02–E05); for several tracks the
/// count and `‹duration› · edits apply to all` (P-INSPECTOR.N01).
struct InspectorHeader: View {
    let tracks: [Track]
    /// Selected tracks (the loaded ones may lag a moment behind).
    let count: Int

    /// UC-SPACE-03: Info header cover 54 pt.
    static let coverSize: CGFloat = 54
    private static let stackedCoverSize: CGFloat = 44

    var body: some View {
        HStack(spacing: Spacing.m) {
            cover
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if count > 1 {
                    Text("\(count.formatted(.number)) tracks selected")
                        .font(.body.weight(.semibold))
                    Text("\(TrackDurationText.total(tracks.reduce(0) { $0 + ($1.duration ?? 0) })) · edits apply to all")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let track = tracks.first {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(TrackMetadataPresentation.artistDisplay(track.artist) ?? "—")
                        .foregroundStyle(TrackMetadataPresentation.artistDisplay(track.artist) == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                    Text(Self.formatLine(track))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // W2-H: the cover becomes the artwork drop target (D-TD-ARTWORK-IN, `.dropDestination(for:
    // Image.self)`, undoable, all selected tracks) and drags out as the track (D-TD-TRACK-OUT).
    @ViewBuilder
    private var cover: some View {
        if count > 1 {
            ZStack(alignment: .topLeading) {
                ForEach(Array(tracks.prefix(3).enumerated()), id: \.offset) { index, track in
                    coverImage(track, size: Self.stackedCoverSize)
                        .offset(x: CGFloat(index) * Spacing.xxs, y: CGFloat(index) * Spacing.xxs)
                }
            }
            .frame(width: Self.coverSize, height: Self.coverSize, alignment: .topLeading)
        } else if let track = tracks.first {
            coverImage(track, size: Self.coverSize)
        }
    }

    @ViewBuilder
    private func coverImage(_ track: Track, size: CGFloat) -> some View {
        Group {
            if track.availability().hasFile, let id = track.id {
                TrackCoverView(trackId: id, size: .large, cornerRadius: 7)
            } else {
                TrackPlaceholderArtwork()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    /// `FLAC · 921 kbps · 6:12`; a track without a file shows its state word instead
    /// (P-INSPECTOR.E05). Never a source name as format.
    static func formatLine(_ track: Track) -> String {
        let availability = track.availability()
        var parts: [String] = []
        if availability.hasFile {
            let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
            if !format.isEmpty { parts.append(format.uppercased()) }
            if let kbps = track.bitrate, kbps > 0 { parts.append("\(kbps) kbps") }
        } else if let status = TrackStatusDisplay.forAvailability(availability) {
            parts.append(status.text)
        }
        if let time = TrackDurationText.trackTime(track.duration) { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inline field issue (UC-SHEET-17)

/// A line under a field: red symbol, `.primary` text, `Try Again` for a failed save.
struct InspectorIssueLine: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
