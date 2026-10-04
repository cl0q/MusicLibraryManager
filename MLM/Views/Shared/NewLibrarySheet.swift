import SwiftUI

/// `New Library` (A3, UI-GROUNDTRUTH §3.17): from File → New Library… or the first run.
/// The library is always created in the default folder; moving it happens in Finder.
struct NewLibrarySheet: View {
    let defaultName: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Library")
                .font(MLMFont.sectionHeader)
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.columns)
            Text("A library keeps its own tracks, playlists and settings. Audio files stay where they are.")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(trimmedName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = defaultName }
    }
}
