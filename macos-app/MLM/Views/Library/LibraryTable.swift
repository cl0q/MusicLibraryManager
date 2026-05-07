import SwiftUI

/// The library track table with sortable columns.
///
/// Uses SwiftUI `Table` (macOS 13+) with all library columns:
/// title, artist, album, format, bitrate, duration, genre, year, energy, date_added.
///
/// Supports multi-select via `$viewModel.selectedTrackIDs` and column sorting
/// via `viewModel.toggleSort(column:)`.
struct LibraryTable: View {
    @Bindable var viewModel: LibraryViewModel

    /// Callback when a track is double-clicked (primary action).
    var onDoubleClick: ((Track) -> Void)?

    var body: some View {
        if viewModel.isLoading {
            loadingState
        } else if let error = viewModel.errorMessage {
            errorState(error)
        } else if viewModel.displayedTracks.isEmpty {
            emptyState
        } else {
            tableView
        }
    }

    // MARK: - Table

    private var tableView: some View {
        Table(viewModel.displayedTracks, selection: $viewModel.selectedTrackIDs) {

            // Title
            TableColumn("Title") { track in
                HStack(spacing: 6) {
                    // Local/Remote status dot
                    Circle()
                        .fill(track.isLocal ? Color.mlmSuccess : Color.mlmActive)
                        .frame(width: 6, height: 6)
                    Text(track.title)
                        .font(MLMFont.tableCell)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 240)

            // Artist
            TableColumn("Artist") { track in
                Text(track.artist)
                    .font(MLMFont.tableCell)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160)

            // Album
            TableColumn("Album") { track in
                Text(track.album)
                    .font(MLMFont.tableCell)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160)

            // Duration
            TableColumn("Time") { track in
                Text(track.formattedDuration)
                    .font(MLMFont.data)
                    .foregroundColor(.mlmInkSecondary)
                    .monospacedDigit()
            }
            .width(50)

            // Format
            TableColumn("Fmt") { track in
                Text(track.isRemote ? "Stream" : track.format.uppercased())
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkMuted)
            }
            .width(50)

            // Bitrate
            TableColumn("kbps") { track in
                Text(track.bitrate.map { "\($0)" } ?? "—")
                    .font(MLMFont.data)
                    .foregroundColor(.mlmInkMuted)
                    .monospacedDigit()
            }
            .width(45)

            // Genre
            TableColumn("Genre") { track in
                Text(track.genre ?? "—")
                    .font(MLMFont.tableCell)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 100)

            // Year
            TableColumn("Year") { track in
                Text(track.year.map { "\($0)" } ?? "—")
                    .font(MLMFont.data)
                    .foregroundColor(.mlmInkMuted)
                    .monospacedDigit()
            }
            .width(40)

            // Energy
            TableColumn("⚡") { track in
                EnergyBars(level: track.energyBucket)
            }
            .width(50)

            // Date Added
            TableColumn("Added") { track in
                Text(formatDateAdded(track.dateAdded))
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }
            .width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Color.mlmBase)
        .contextMenu(forSelectionType: Int64.self) { selectedIDs in
            TrackContextMenu(
                selectedTrackIDs: selectedIDs,
                tracks: viewModel.displayedTracks
            )
        } primaryAction: { selectedIDs in
            // Double-click — play track + show detail
            if let trackID = selectedIDs.first,
               let track = viewModel.displayedTracks.first(where: { $0.id == trackID }) {
                onDoubleClick?(track)
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading tracks...")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.mlmError)
            Text("Failed to load tracks")
                .font(MLMFont.bodyBold)
                .foregroundColor(.mlmInk)
            Text(message)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.searchQuery.isEmpty ? "music.note" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.mlmInkMuted)
            Text(viewModel.searchQuery.isEmpty
                 ? (viewModel.selectedTab == .local ? "No local tracks" : "No remote tracks")
                 : "No results for \"\(viewModel.searchQuery)\"")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
            if viewModel.searchQuery.isEmpty && viewModel.selectedTab == .local {
                Text("Import music or download from Remote to get started.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }

    // MARK: - Helpers

    /// Format date_added for display (e.g., "2026-05-07" → "May 7").
    private func formatDateAdded(_ dateString: String?) -> String {
        guard let dateString else { return "—" }

        // Parse ISO 8601 date (e.g., "2026-05-07T12:00:00Z" or "2026-05-07")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]

        if let date = formatter.date(from: String(dateString.prefix(10))) {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return display.string(from: date)
        }

        // Fallback: return first 10 chars
        return String(dateString.prefix(10))
    }
}
