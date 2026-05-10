import SwiftUI

/// Duplicate review queue — approve or dismiss flagged duplicate pairs.
struct ReviewQueueView: View {
    @Environment(\.container) private var container
    @State private var viewModel: ReviewQueueViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                reviewContent(vm: vm)
            } else {
                ProgressView("Loading...")
            }
        }
        .task {
            guard let analysisRepo = container.analysisRepository,
                  let trackRepo = container.trackRepository else { return }
            let vm = ReviewQueueViewModel(
                analysisRepository: analysisRepo,
                trackRepository: trackRepo
            )
            viewModel = vm
            await vm.loadPendingReviews()
        }
    }

    @ViewBuilder
    private func reviewContent(vm: ReviewQueueViewModel) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Duplicate Review")
                        .font(MLMFont.title3)
                    Text("\(vm.pendingItems.count) pending items")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }

                Spacer()

                Button {
                    Task { await vm.startDeepScan() }
                } label: {
                    if vm.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Deep Scan", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .disabled(vm.isScanning)
            }
            .padding(16)

            Divider()

            // Scan result
            if let result = vm.scanResult {
                HStack(spacing: 16) {
                    Label("\(result.pairsCompared) compared", systemImage: "arrow.left.arrow.right")
                    Label("\(result.duplicatesFound) duplicates", systemImage: "doc.on.doc")
                    Label("\(result.conflictsFlagged) conflicts", systemImage: "exclamationmark.triangle")
                }
                .font(MLMFont.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.mlmSurface)
            }

            // Items
            if vm.pendingItems.isEmpty && !vm.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    Text("No pending reviews")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Text("Run Deep Scan to find potential duplicates")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.pendingItems) { item in
                        ReviewItemRow(
                            item: item,
                            trackA: vm.trackDetails[item.trackId],
                            trackB: item.relatedTrackId.flatMap { vm.trackDetails[$0] },
                            onResolve: { Task { await vm.resolveItem(item) } },
                            onDismiss: { Task { await vm.dismissItem(item) } }
                        )
                    }
                }
                .listStyle(.inset)
            }

            // Error
            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(MLMFont.muted)
                    .padding(16)
            }
        }
        .background(Color.mlmBase)
    }
}

// MARK: - Review Item Row

struct ReviewItemRow: View {
    let item: ReviewItem
    let trackA: Track?
    let trackB: Track?
    let onResolve: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Type badge
            HStack {
                Text(item.actionType == "fingerprint_dedup" ? "Fingerprint Match" : "Metadata Conflict")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(item.actionType == "fingerprint_dedup" ? .orange : .yellow)

                if let action = item.autoAction {
                    Text("(\(action))")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }

                Spacer()
            }

            // Track comparison
            HStack(spacing: 16) {
                if let a = trackA {
                    trackInfo(a, label: "Track A")
                }
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.mlmInkMuted)
                if let b = trackB {
                    trackInfo(b, label: "Track B")
                }
            }

            // Actions
            HStack {
                Spacer()
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button("Resolve") {
                    onResolve()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func trackInfo(_ track: Track, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
            Text(track.title)
                .font(MLMFont.body)
            Text(track.artist)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
            HStack(spacing: 8) {
                Text(track.format.uppercased())
                    .font(MLMFont.mono)
                if let bitrate = track.bitrate {
                    Text("\(bitrate / 1000)kbps")
                        .font(MLMFont.mono)
                }
            }
            .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
