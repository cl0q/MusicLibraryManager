import SwiftUI

/// Diff-preview sheet for m3u8 ingest (WP4).
///
/// Shows the target playlist, counts + entry lists for added/removed/reordered,
/// and unresolved entries with reasons (warning styling). Apply + Cancel buttons.
///
/// Mirrors the structure of sync preview patterns in SyncProfileDetailView:
/// sectioned DisclosureGroups with counts, accent-colored stats, and error surfacing
/// inline at the bottom of the sheet.
struct IngestPreviewView: View {
    let preview: IngestPreview
    let sourceFileName: String
    let onApply: () -> Void
    let onCancel: () -> Void

    var isApplying: Bool = false
    var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .foregroundColor(.mlmAccent)
                    Text("Import Playlist")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                }
                Text("From \(sourceFileName)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }

            Divider()

            // Target playlist
            targetPlaylistSection

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary counts
                    summarySection

                    // Added entries
                    if !preview.added.isEmpty {
                        entrySection(
                            title: "Added",
                            count: preview.added.count,
                            entries: preview.added,
                            icon: "plus.circle.fill",
                            tint: .mlmSuccess
                        )
                    }

                    // Removed entries
                    if !preview.removed.isEmpty {
                        entrySection(
                            title: "Removed",
                            count: preview.removed.count,
                            entries: preview.removed,
                            icon: "minus.circle.fill",
                            tint: .mlmError
                        )
                    }

                    // Reordered entries
                    if !preview.reordered.isEmpty {
                        entrySection(
                            title: "Reordered",
                            count: preview.reordered.count,
                            entries: preview.reordered,
                            icon: "arrow.up.arrow.down.circle.fill",
                            tint: .mlmActive
                        )
                    }

                    // Unresolved entries (warning styling)
                    if !preview.unresolved.isEmpty {
                        unresolvedSection
                    }

                    // Error
                    if let applyError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.mlmError)
                            Text(applyError)
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmError)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mlmError.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.mlmError.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .disabled(isApplying)

                Spacer()

                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }

                Button(preview.willCreate ? "Create & Import" : "Apply") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mlmAccent)
                .disabled(isApplying || (preview.isEmpty && preview.unresolved.isEmpty))
            }
        }
        .padding(20)
        .frame(minWidth: 480, maxWidth: 560, minHeight: 400, maxHeight: 640)
    }

    // MARK: - Sections

    private var targetPlaylistSection: some View {
        HStack(spacing: 8) {
            Image(systemName: preview.willCreate ? "sparkles" : "music.note.list")
                .foregroundColor(.mlmAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.targetPlaylistName)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                Text(preview.willCreate ? "Will create new playlist" : "Existing playlist")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var summarySection: some View {
        HStack(spacing: 16) {
            summaryChip(count: preview.added.count, label: "Added", tint: .mlmSuccess)
            summaryChip(count: preview.removed.count, label: "Removed", tint: .mlmError)
            summaryChip(count: preview.reordered.count, label: "Reordered", tint: .mlmActive)
            if !preview.unresolved.isEmpty {
                summaryChip(count: preview.unresolved.count, label: "Unresolved", tint: .mlmWarning)
            }
        }
    }

    private func summaryChip(count: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(MLMFont.bodyBold)
                .foregroundColor(tint)
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
        }
    }

    private func entrySection(
        title: String,
        count: Int,
        entries: [IngestPreview.Entry],
        icon: String,
        tint: Color
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInk)
                            .lineLimit(1)
                        if !entry.artist.isEmpty {
                            Text("— \(entry.artist)")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(entry.path)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text("\(title) (\(count))")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
        }
    }

    private var unresolvedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.unresolved) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.path)
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInk)
                            .lineLimit(1)
                        Text(entry.reason)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmWarning)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmWarning)
                Text("Unresolved (\(preview.unresolved.count))")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmWarning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mlmWarning.opacity(0.2), lineWidth: 1)
        )
    }
}
