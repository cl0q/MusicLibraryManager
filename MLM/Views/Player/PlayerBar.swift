import AppKit
import SwiftUI

/// The toolbar player (P-PLAYER, UC-TB-06/07/09, §15.7), centred via `.principal`.
///
/// Left to right: Previous · Play/Pause · Next · cover (28 pt → large-cover popover) · title /
/// state line + second line (click → Go to Current Track ⌘L) · elapsed · scrubber (a waveform
/// while previewing) · duration (hidden when idle) · volume (popover, remembered, ⌘↑/⌘↓) ·
/// queue button. No background or material of its own: the toolbar is its surface
/// (UC-GLASS-01/08). Space never reaches it (§10 Q1).
struct PlayerBar: View {
    let viewModel: PlaybackViewModel

    var body: some View {
        // Narrow windows give way in a fixed order (UC-TB-03): the title / artist column goes
        // first; transport, scrubber, volume and the queue button stay.
        ViewThatFits(in: .horizontal) {
            playerRow(showsTrackInfo: true)
            playerRow(showsTrackInfo: false)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .frame(minWidth: Self.minimumWidth, idealWidth: 620, maxWidth: 800)
        // No background of its own: the toolbar's system glass is the player's surface
        // (UC-TB-06, UC-GLASS-01/08).
        .background { PlayerNoticeRelay(viewModel: viewModel) }
        .locateFilePanel()
    }

    /// Width below which the toolbar moves items to its overflow instead of squeezing the
    /// player further (transport + cover + scrubber + volume + queue button).
    static let minimumWidth: CGFloat = 340

    /// The title / artist column's width; titles truncate inside it.
    static let trackInfoWidth: CGFloat = 160

    /// The toolbar player's cover (UC-SPACE-03).
    static let coverSize: CGFloat = 28

    @MainActor
    private var display: PlayerDisplay {
        let preview = viewModel.preview
        return PlayerDisplay.make(current: viewModel.currentTrack,
                                  preview: preview.isActive ? preview.track : nil,
                                  cantPlay: viewModel.cantPlay)
    }

    private func playerRow(showsTrackInfo: Bool) -> some View {
        let display = self.display
        return HStack(spacing: Spacing.s) {
            PlayerTransport(viewModel: viewModel)
            PlayerCover(viewModel: viewModel, display: display)
            if showsTrackInfo {
                PlayerTitleColumn(viewModel: viewModel, display: display)
                    // A fixed width, so whether the column fits (UC-TB-03) depends only on the
                    // window's width, never on the length of the playing title.
                    .frame(width: Self.trackInfoWidth, alignment: .leading)
            }
            PlayerScrubber(viewModel: viewModel, showsTimes: display.showsTimes)
                .layoutPriority(2)
            PlayerVolumeButton(viewModel: viewModel)
            queueButton
        }
    }

    // MARK: - Queue button (UC-TB-06)

    @Environment(TrailingColumnState.self) private var trailingColumn: TrailingColumnState?

    /// Opens / closes the trailing column in Queue mode (⌥⌘U, UC-TRAIL-01).
    private var queueButton: some View {
        let showing = trailingColumn?.isShowing(.queue) == true
        return Button {
            trailingColumn?.toggle(.queue)
        } label: {
            Image(systemName: "list.bullet")
                .foregroundStyle(showing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .disabled(trailingColumn == nil)
        .help(showing ? "Hide Queue ⌥⌘U" : "Show Queue ⌥⌘U")
        .accessibilityLabel(showing ? "Hide Queue" : "Show Queue")
    }
}

// MARK: - Transport (E01–E03)

private struct PlayerTransport: View {
    let viewModel: PlaybackViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hasTrack = viewModel.hasTrack
        let canPlayPause = hasTrack || viewModel.preview.isActive
        let isPlaying = viewModel.isPlaying
        HStack(spacing: Spacing.xxs) {
            Button {
                Task { await viewModel.back() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!hasTrack)
            .help("Previous ⌘←")
            .accessibilityIdentifier("back_button")
            .accessibilityLabel("Previous")

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .imageScale(.large)
                    // The only motion in the player (UC-MOTION-02), off with Reduce Motion.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(minWidth: Spacing.xl)
            }
            .disabled(!canPlayPause)
            .accessibilityIdentifier("play_pause_button")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasTrack)
            .help("Next ⌘→")
            .accessibilityIdentifier("forward_button")
            .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Cover (E04, S-PLAYER-COVER)

private struct PlayerCover: View {
    let viewModel: PlaybackViewModel
    let display: PlayerDisplay
    @State private var showsLargeCover = false

    var body: some View {
        Button {
            showsLargeCover.toggle()
        } label: {
            Group {
                if let id = display.coverTrackID {
                    TrackCoverView(trackId: id, size: .small, cornerRadius: 4)
                } else {
                    TrackPlaceholderArtwork()
                }
            }
            .frame(width: PlayerBar.coverSize, height: PlayerBar.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(display.coverTrackID == nil)
        .help("Show Cover")
        .accessibilityLabel("Show Cover")
        // The system popover container (UC-GLASS-06): no custom background, no shadow.
        .popover(isPresented: $showsLargeCover, arrowEdge: .bottom) {
            LargeCoverPopover(viewModel: viewModel, display: display)
        }
    }
}

/// S-PLAYER-COVER: 300 pt cover, names, Go to Album, Go to Current Track ⌘L.
private struct LargeCoverPopover: View {
    let viewModel: PlaybackViewModel
    let display: PlayerDisplay
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @FocusedValue(\.toolbarSearch) private var search
    @Environment(\.dismiss) private var dismiss

    static let size: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let id = display.coverTrackID {
                TrackCoverView(trackId: id, size: .large, cornerRadius: 9)
                    .frame(width: Self.size, height: Self.size)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(display.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let second = display.secondLine {
                    Text(second)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack {
                // Album pages arrive with W4-2: present, disabled with the reason (UC-COPY-13).
                Button(MenuCommand.goToAlbum.title) {}
                    .disabled(true)
                    .help(MenuCommand.goToAlbum.pendingReason ?? "")
                Spacer(minLength: Spacing.s)
                Button("Go to Current Track") {
                    GoToCurrentTrack.perform(playback: viewModel, navigation: navigation, search: search)
                    dismiss()
                }
                .disabled(viewModel.currentTrack == nil)
                .help("Go to Current Track ⌘L")
            }
        }
        .frame(width: Self.size)
        .padding()
    }
}

// MARK: - Title / state line (E05–E07, UC-TB-07)

private struct PlayerTitleColumn: View {
    let viewModel: PlaybackViewModel
    let display: PlayerDisplay
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @FocusedValue(\.toolbarSearch) private var search

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine
            secondLine
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var titleLine: some View {
        switch display.mode {
        case .idle:
            Text(display.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .preview(let tag):
            HStack(spacing: Spacing.xxs) {
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xxs)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(display.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        case .track:
            // Click = Go to Current Track ⌘L (E05).
            Button {
                GoToCurrentTrack.perform(playback: viewModel, navigation: navigation, search: search)
            } label: {
                Text(display.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Go to Current Track ⌘L")
        case .cantPlay:
            Text(display.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        if let line = display.secondLine {
            HStack(spacing: Spacing.xxs) {
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let fix = display.fixTitle {
                    Text("·").accessibilityHidden(true)
                    Button(fix) { performFix() }
                        .buttonStyle(.link)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func performFix() {
        guard let cantPlay = viewModel.cantPlay else { return }
        switch cantPlay.reason {
        case .notDownloaded:
            TrackCommandActions.download([cantPlay.track])
        case .fileMissing:
            LocateFileRequest.shared.begin(cantPlay.track)
        case .driveNotConnected, .unreadable:
            break
        }
    }
}

// MARK: - Scrubber and times (E08, E09)

private struct PlayerScrubber: View {
    let viewModel: PlaybackViewModel
    let showsTimes: Bool
    @State private var isSeeking = false
    @State private var seekFraction: Double = 0

    var body: some View {
        let preview = viewModel.preview
        let previewing = preview.isActive
        let position = previewing ? viewModel.previewPosition : viewModel.currentPosition
        let duration = previewing ? viewModel.previewDuration : viewModel.duration
        HStack(spacing: Spacing.xs) {
            timeText(position, visible: showsTimes)
            if previewing {
                PreviewWaveformScrubber(
                    peaks: viewModel.previewWaveform,
                    progress: duration > 0 ? position / duration : 0,
                    hotSpot: duration > 0 ? (preview.hotSpot ?? 0) / duration : nil
                ) { fraction in
                    viewModel.seekToProgress(fraction)
                }
                .accessibilityIdentifier("position_slider")
            } else {
                Slider(value: binding, in: 0...1) { editing in
                    if editing {
                        seekFraction = viewModel.progress
                        isSeeking = true
                    } else {
                        viewModel.seekToProgress(seekFraction)
                        isSeeking = false
                    }
                }
                .controlSize(.mini)
                .disabled(!viewModel.hasTrack)
                .accessibilityIdentifier("position_slider")
                .accessibilityLabel("Position")
            }
            timeText(duration, visible: showsTimes)
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { isSeeking ? seekFraction : viewModel.progress },
            set: { seekFraction = $0 }
        )
    }

    /// `1:12` / `5:48`; hidden (but keeping its place) when idle (E08).
    private func timeText(_ seconds: TimeInterval, visible: Bool) -> some View {
        Text(PlaybackWords.time(seconds))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }
}

// MARK: - Volume (E10)

private struct PlayerVolumeButton: View {
    let viewModel: PlaybackViewModel
    @State private var showsSlider = false

    private static let sliderWidth: CGFloat = 160

    var body: some View {
        Button {
            showsSlider.toggle()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help("Volume")
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(viewModel.volume, format: .percent.precision(.fractionLength(0))))
        .popover(isPresented: $showsSlider, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: Binding(get: { viewModel.volume }, set: { viewModel.setVolume($0) }), in: 0...1)
                        .frame(width: Self.sliderWidth)
                        .accessibilityLabel("Volume")
                        .accessibilityIdentifier("volume_slider")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text("⌘↑ / ⌘↓ · remembered between launches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var symbol: String {
        let volume = viewModel.volume
        if volume < 0.01 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Status-bar notes

/// Shows the player's notes (skips, refusals, failures) in this window's status bar, each
/// with its one action (UC-STATUS-04/05/07). A leaf, so position ticks don't reach it.
private struct PlayerNoticeRelay: View {
    let viewModel: PlaybackViewModel
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: viewModel.notice?.id) { _, _ in
                guard let notice = viewModel.notice else { return }
                statusBar?.post(notice.text, actions: notice.action.map { [statusAction($0)] } ?? [])
            }
    }

    private func statusAction(_ action: PlaybackNotice.Action) -> StatusAction {
        switch action {
        case .download(let tracks):
            StatusAction("Download") { TrackCommandActions.download(tracks) }
        case .locate(let track):
            StatusAction("Locate…") { LocateFileRequest.shared.begin(track) }
        case .showInFinder(let url):
            StatusAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .tryAgain(let track):
            StatusAction("Try Again") { [viewModel] in Task { await viewModel.playTrack(track) } }
        }
    }
}
