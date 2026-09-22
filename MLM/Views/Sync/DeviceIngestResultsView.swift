import SwiftUI

/// Combined summary view for device playlist scan results (WP4 Trigger B).
///
/// Shows all m3u8 files found on the device that have changes, with per-file
/// previews. User can apply each individually. Applied files are removed
/// from the list so they don't clobber each other.
struct DeviceIngestResultsView: View {
    let profile: SyncProfile

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    private var vm: SyncViewModel? { container.syncViewModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "ipod")
                        .foregroundColor(.mlmAccent)
                    Text("Read Playlist Changes")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                }
                Text("From \(profile.name) — \(profile.outputFolder)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            if let vm {
                content(vm)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Button("Close") {
                    container.syncViewModel?.clearDeviceScanResults()
                    dismiss()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 500, maxWidth: 600, minHeight: 360, maxHeight: 560)
    }

    @ViewBuilder
    private func content(_ vm: SyncViewModel) -> some View {
        if vm.isScanningDevice {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning device for playlist changes…")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.deviceScanError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmError)
                Text(error)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmError)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.deviceIngestPreviews.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.mlmSuccess)
                Text("No playlist changes found")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                Text("All playlists on the device match the last sync.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // List of changed files
            ScrollView {
                VStack(spacing: 12) {
                    Text("\(vm.deviceIngestPreviews.count) playlist\(vm.deviceIngestPreviews.count == 1 ? "" : "s") with changes")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(Array(vm.deviceIngestPreviews.enumerated()), id: \.offset) { index, item in
                        DeviceIngestFileRow(
                            fileName: item.fileName,
                            preview: item.preview,
                            onApply: {
                                Task {
                                    let outputFolder = profile.outputFolder
                                    let fullPath = (outputFolder as NSString).appendingPathComponent(item.fileName)
                                    let fileURL = URL(fileURLWithPath: fullPath)
                                    _ = await vm.applyDeviceIngest(at: index, profile: profile, fileURL: fileURL)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

/// A single file row in the device ingest results.
struct DeviceIngestFileRow: View {
    let fileName: String
    let preview: IngestPreview
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundColor(.mlmAccent)
                Text(fileName)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)
                Spacer()
                Text(preview.targetPlaylistName)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                if preview.willCreate {
                    Text("(new)")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmActive)
                }
            }

            // Summary chips
            HStack(spacing: 12) {
                if !preview.added.isEmpty {
                    Label("+\(preview.added.count)", systemImage: "plus.circle.fill")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmSuccess)
                }
                if !preview.removed.isEmpty {
                    Label("-\(preview.removed.count)", systemImage: "minus.circle.fill")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                }
                if !preview.reordered.isEmpty {
                    Label("↕ \(preview.reordered.count)", systemImage: "arrow.up.arrow.down.circle.fill")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmActive)
                }
                if !preview.unresolved.isEmpty {
                    Label("⚠ \(preview.unresolved.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmWarning)
                }
            }

            HStack {
                Spacer()
                Button("Apply") {
                    onApply()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.mlmRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mlmEdge, lineWidth: 1)
        )
    }
}
