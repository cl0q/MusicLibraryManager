import SwiftUI

/// Discovery Inbox View — field-test and approve/reject swarm-intelligence suggested tracks.
struct DiscoveryInboxView: View {
    @Environment(\.container) private var container
    @State private var inboxItems: [(track: Track, log: TrackDiscoveryLog, seedTrack: Track?)] = []
    @State private var isLoading = false
    @State private var alertMessage: String?
    @State private var showingAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discovery Inbox")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                    Text("\(inboxItems.count) recommended neighbors waiting for review")
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
                    ProgressView("Loading discovery inbox...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inboxItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.mlmInkMuted)
                    Text("Your Discovery Inbox is empty")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Text("Find recommendations for local tracks using Swarm Intelligence and download them to list them here.")
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
                                Task { await rejectTrack(item) }
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
        .alert("Discovery Inbox", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = alertMessage {
                Text(msg)
            }
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
        guard let trackRepo = container.trackRepository else { return }
        guard let trackId = item.track.id else { return }
        
        do {
            // 1. Update discovery status to 'approved'
            try await trackRepo.updateDiscoveryStatus(discoveredTrackId: trackId, status: "approved")
            
            // 2. Direct Similarity Feedback Boost (feedbackValue = 1)
            if let seedId = item.log.seedTrackId {
                try await trackRepo.saveSimilarityFeedback(
                    seedTrackId: seedId,
                    targetTrackId: trackId,
                    feedbackValue: 1
                )
                
                // 3. Vector Gravity (pullRate = 0.05) to warp local embedding space
                try await trackRepo.applyVectorGravity(
                    seedTrackId: seedId,
                    targetTrackId: trackId,
                    pullRate: 0.05
                )
                
                AppLogger.shared.info(
                    "Approved suggested track '\(item.track.title)' by \(item.track.artist). Local Vector Gravity learning applied.",
                    source: "Discovery"
                )
            }

            // Post notification to reload views
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            
            await loadInboxItems()
        } catch {
            alertMessage = "Failed to approve track: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func rejectTrack(_ item: (track: Track, log: TrackDiscoveryLog, seedTrack: Track?)) async {
        guard let trackRepo = container.trackRepository else { return }
        guard let trackId = item.track.id else { return }

        do {
            // 1. Delete physical file from disk if it exists
            let rawPath = item.track.originalPath
            if !rawPath.isEmpty {
                let fileURL = URL(fileURLWithPath: rawPath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                    AppLogger.shared.info("Deleted rejected discovery physical file: \(fileURL.lastPathComponent)", source: "Discovery")
                }
            }

            // 2. Delete track from database (cascades automatically to track_discovery_log)
            try await trackRepo.delete(id: trackId)
            
            AppLogger.shared.info(
                "Rejected suggested track '\(item.track.title)' by \(item.track.artist). Track fully purged.",
                source: "Discovery"
            )

            // Post notification to reload views
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            
            await loadInboxItems()
        } catch {
            alertMessage = "Failed to reject track: \(error.localizedDescription)"
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
                AppLogger.shared.debug("Drop-Fokus: Seeking straight to drop at \(Int(embedding.dropOffset))s", source: "Discovery")
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
                        
                        Text("🔗 Neighbor of \(seed.title)")
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
                Button(action: onPreview) {
                    Image(systemName: "headphones")
                        .foregroundColor(.mlmAccent)
                }
                .buttonStyle(.plain)
                .help("Play Drop-Fokus Preview")
                
                Button(action: onApprove) {
                    Image(systemName: "hand.thumbsup.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Approve & Warp Embeddings")
                
                Button(action: onReject) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .foregroundColor(.mlmError)
                }
                .buttonStyle(.plain)
                .help("Reject & Purge File")
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
