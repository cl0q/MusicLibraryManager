import AppKit
import AVKit
import SwiftUI

/// The workbench of the selected reel (V-REELS.N03): everything in reading order — watch it, see
/// the guesses, settle artist and title, get the song. No jargon labels.
struct ReelWorkbench: View {
    @Bindable var model: ReelsModel

    @Environment(\.container) private var container

    @State private var player = AVPlayer()
    @State private var shownReelID: String?

    var body: some View {
        Group {
            if let item = model.focusedItem, let bench = model.focusedBench {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        titleRow(item, bench)
                        HStack(alignment: .top, spacing: Spacing.xl) {
                            ReelVideoColumn(model: model, player: player, item: item, bench: bench)
                                .frame(width: 210)
                            VStack(alignment: .leading, spacing: Spacing.xl) {
                                ReelGuessesSection(model: model, item: item, bench: bench)
                                ReelSongSection(model: model, bench: bench)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        ReelResultsSection(model: model, bench: bench)
                    }
                    .padding(Spacing.l)
                }
                // Space plays or pauses the video while the workbench has focus (V-REELS.E06).
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    model.toggleVideo()
                    return .handled
                }
            } else {
                ContentUnavailableView("No reel selected", systemImage: "video")
            }
        }
        .onChange(of: model.focusedID, initial: true) { _, id in show(id) }
        .onChange(of: model.playRequest) { _, request in handle(request) }
        // Never two things sounding: a track or preview that starts pauses the video.
        .onChange(of: container.playbackViewModel?.isPlaying ?? false) { _, playing in
            if playing { player.pause() }
        }
        .onDisappear { player.pause() }
    }

    // MARK: Title row (V-REELS.N04, N05)

    private func titleRow(_ item: ReelItem, _ bench: ReelBench) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.state.word) · imported \(item.createdAt.formatted(.dateTime.month(.abbreviated).day().year())) · \((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Spacing.s)
            Button(bench.hasIdentified ? "Identify Again" : "Identify") {
                Task { await model.identify(item.id) }
            }
            .disabled(bench.isIdentifying)
            Button("Mark as Done") { Task { await model.markDone([item.id]) } }
                .disabled(item.state == .done)
            Button("Delete Reel…", role: .destructive) { model.requestDelete([item.id]) }
        }
    }

    // MARK: The video (V-REELS.E06)

    private func show(_ id: String?) {
        guard id != shownReelID else { return }
        shownReelID = id
        player.pause()
        if let item = id.flatMap(model.item(for:)), FileManager.default.fileExists(atPath: item.url.path) {
            player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        } else {
            player.replaceCurrentItem(with: nil)
        }
    }

    private func handle(_ request: ReelPlayRequest?) {
        guard let request, request.reelID == model.focusedID, player.currentItem != nil else { return }
        if request.toggles, player.timeControlStatus != .paused {
            player.pause()
            return
        }
        // Starting the video pauses whatever else is sounding.
        if container.playbackViewModel?.isPlaying == true { container.playbackViewModel?.pause() }
        if let offset = request.offset {
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }
}

// MARK: - Video and stills (V-REELS.E06, E16, S-REELS-KEYFRAME)

private struct ReelVideoColumn: View {
    let model: ReelsModel
    let player: AVPlayer
    let item: ReelItem
    let bench: ReelBench

    @State private var shownFrame: ReelKeyframe?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Group {
                if bench.videoReachable {
                    VideoPlayer(player: player)
                } else {
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "video.slash")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("The video file is not reachable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if !bench.keyframes.isEmpty {
                Text("Stills").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(bench.keyframes) { frame in
                            Button { shownFrame = frame } label: {
                                VStack(spacing: 2) {
                                    Image(decorative: frame.image.cgImage, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 40, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    Text(ReelGuesses.timecode(frame.offset))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Still at \(ReelGuesses.timecode(frame.offset))")
                            .popover(item: popoverBinding(for: frame), arrowEdge: .bottom) { frame in
                                ReelKeyframePopover(model: model, reelID: item.id, frame: frame)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if bench.stills == .reading {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Reading the video…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One popover at a time; Esc or a click outside closes it (K-REELS-KEYFRAME-ESC).
    private func popoverBinding(for frame: ReelKeyframe) -> Binding<ReelKeyframe?> {
        Binding(get: { shownFrame == frame ? frame : nil }, set: { if $0 == nil && shownFrame == frame { shownFrame = nil } })
    }
}

/// S-REELS-KEYFRAME — a glance, not a sheet: the still, the text found in it, `Play from Here`
/// and the same Use actions as the fragments.
private struct ReelKeyframePopover: View {
    let model: ReelsModel
    let reelID: String
    let frame: ReelKeyframe

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(decorative: frame.image.cgImage, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Still at \(ReelGuesses.timecode(frame.offset))").bold()
                    Button("Play from Here") {
                        model.playVideo(reelID, from: frame.offset)
                        dismiss()
                    }
                    .buttonStyle(.link)
                }
                Text("Text in this still")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if frame.texts.isEmpty {
                    Text("No text found in this still.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(frame.texts, id: \.self) { text in
                                ReelFragmentCapsule(model: model, text: text)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .frame(width: 420, height: 200)
    }
}

// MARK: - Fragments (CM-REELS-TEXTPILL)

/// A text fragment as a capsule with its menu: `Use as Artist · Use as Title · Use as
/// “Artist – Title” (disabled when it can't be split) — Copy`.
struct ReelFragmentCapsule: View {
    let model: ReelsModel
    let text: String

    var body: some View {
        Menu {
            Button("Use as Artist") { Task { await model.use(fragment: text, as: .artist) } }
            Button("Use as Title") { Task { await model.use(fragment: text, as: .title) } }
            Button("Use as “Artist – Title”") { Task { await model.use(fragment: text, as: .artistAndTitle) } }
                .disabled(!ArtistTitleSplit.canSplit(text))
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } label: {
            Text(text).lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
    }
}
