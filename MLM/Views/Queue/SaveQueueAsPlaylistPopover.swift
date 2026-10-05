import SwiftUI

/// Save Queue as Playlist (P-QUEUE.N15) — the one naming popover (UC-SHEET-10, §23 C8): a name
/// field prefilled `Queue — ‹date›`, the count, `Cancel` and `Create` (Return creates, Esc
/// cancels). Now playing + Next in queue order become a new playlist as one undo step; the
/// queue is unchanged and the window does not navigate. System popover, no background of its
/// own (UC-GLASS-06).
struct SaveQueueAsPlaylistPopover: View {
    /// Tracks the playlist will get (a track queued twice is added once).
    let trackCount: Int
    let create: (String) -> Void
    let cancel: () -> Void

    @State private var name = QueuePanelWords.defaultPlaylistName()
    @FocusState private var nameFocused: Bool

    /// The popover's width (`queue.html` P-QUEUE.N15).
    static let width: CGFloat = 270

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(QueuePanelWords.saveTitle)
                .font(.headline)
            TextField("Name", text: $name)
                .labelsHidden()
                .focused($nameFocused)
                .onSubmit(submit)
            Text(QueuePanelWords.saveCount(trackCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(QueuePanelWords.saveCancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(QueuePanelWords.saveCreate, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: Self.width)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        create(trimmedName)
    }
}
