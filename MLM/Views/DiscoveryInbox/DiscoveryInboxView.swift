import SwiftUI

/// Discovery Inbox View — field-test and approve/reject swarm-intelligence suggested tracks.
struct DiscoveryInboxView: View {
    @Environment(\.container) private var container
    @State private var inboxItems: [(track: Track, log: TrackDiscoveryLog, seedTrack: Track?)] = []
    @State private var isLoading = false
    @State private var alertMessage: String?
    @State private var showingAlert = false
    @State private var trackPendingDeletion: Track?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommendations")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                    Text("\(inboxItems.count) recommendations waiting for review")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }
                Spacer()
                
                Button {
                    Task { await loadInboxItems() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding(16)
            
            Divider()

            if isLoading {
                VStack {
                    ProgressView("Loading recommendations…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inboxItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.mlmInkMuted)
                    Text("No recommendations yet")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Text("Open a track's Similar tab to find and download recommendations.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(inboxItems, id: \.track.id) { item in
                        DiscoveryInboxRow(
                            track: item.track,
                            log: item.log,
                            seedTrack: item.seedTrack,
                            onApprove: {
                                Task { await approveTrack(item) }
                            },
                            onReject: {
                                trackPendingDeletion = item.track
                                showingDeleteConfirmation = true
                            },
                            onPreview: {
                                playDropPreview(item.track)
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color.mlmBase)
        .alert("Recommendations", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = alertMessage {
                Text(msg)
            }
        }
        .alert("Delete file?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                guard let track = trackPendingDeletion else { return }
                trackPendingDeletion = nil
                Task { await rejectTrack(track) }
            }
        } message: {
            Text("The file will be moved to the Trash.")
        }
        .task {
            await loadInboxItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await loadInboxItems() }
        }
    }

    // MARK: - Actions

    private func loadInboxItems() async {
        guard let trackRepo = container.trackRepository else { return }
        isLoading = true
        do {
            let items = try await trackRepo.fetchDiscoveryInboxTracks()
            await MainActor.run {
                self.inboxItems = items
                self.isLoading = false
            }
        } catch {
            AppLogger.shared.error("Failed to load discovery inbox: \(error.localizedDescription)", source: "Discovery")
            isLoading = false
        }
    }

    private func approveTrack(_ item: (track: Track, log: TrackDiscoveryLog, seedTrack: Track?)) async {
        guard let reviewService = container.discoveryReviewService else { return }
        do {
            try await reviewService.accept(
                track: item.track,
                seedTrackID: item.log.seedTrackId,
                source: item.log.discoverySource
            )
            await loadInboxItems()
        } catch {
            alertMessage = "Could not add this recommendation to your library."
            showingAlert = true
        }
    }

    private func rejectTrack(_ track: Track) async {
        guard let reviewService = container.discoveryReviewService else { return }

        do {
            try await reviewService.delete(track: track)
            await loadInboxItems()
        } catch {
            alertMessage = "Could not delete this recommendation."
            showingAlert = true
        }
    }

    private func playDropPreview(_ track: Track) {
        guard let playbackVM = container.playbackViewModel else { return }
        Task {
            // Play the track
            await playbackVM.playTrack(track)
            
            // Check if there is a drop offset from the CoreML Analysis stage
            if let trackId = track.id,
               let embedding = try? await container.trackRepository?.fetchTrackEmbedding(id: trackId),
               embedding.dropOffset > 0 {
                // Seek straight to the Drop
                playbackVM.seek(to: embedding.dropOffset)
                AppLogger.shared.debug("Previewing from detected audio point at \(Int(embedding.dropOffset))s", source: "Discovery")
            }
        }
    }
}

// MARK: - Row View

struct DiscoveryInboxRow: View {
    let track: Track
    let log: TrackDiscoveryLog
    let seedTrack: Track?
    
    let onApprove: () -> Void
    let onReject: () -> Void
    let onPreview: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                .frame(width: 40, height: 40)
            
            // Title & Artist
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(track.artist)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                        .lineLimit(1)
                    
                    if let seed = seedTrack {
                        Text("•")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                        
                        Text("Recommended because you liked \"\(seed.title)\"")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmAccent)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // Source Badge
            Text(log.discoverySource.uppercased())
                .font(MLMFont.mono)
                .font(.system(size: 9))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(sourceBadgeColor)
                )
            
            // Action Buttons
            HStack(spacing: 8) {
                Button("Preview", action: onPreview)
                    .buttonStyle(.bordered)
                Button("Add to library", action: onApprove)
                    .buttonStyle(.bordered)
                Button("Delete…", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
    
    private var sourceBadgeColor: Color {
        switch log.discoverySource.lowercased() {
        case "soundcloud":
            return Color.orange
        case "lastfm":
            return Color.red
        default:
            return Color.mlmInkMuted
        }
    }
}
