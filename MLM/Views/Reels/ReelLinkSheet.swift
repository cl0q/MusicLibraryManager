import AppKit
import SwiftUI

/// S-REELS-LINK — `Add Reel from Link`: the same shape as `Add from Link` (one field, Paste,
/// the refusal inline above the buttons, Cancel on Esc, Return adds). The fetch runs as an
/// Activity operation (`Fetching reel…`); the sheet closes at once and the reel appears as `New`.
struct ReelLinkSheet: View {
    let model: ReelsModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Reel from Link")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    HStack {
                        TextField("Link", text: $text, prompt: Text("https://www.instagram.com/reel/…"))
                            .labelsHidden()
                            .onSubmit(add)
                        Button("Paste") {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                refusal = nil
                            }
                        }
                    }
                    Text(ReelLinkParser.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let refusal {
                Text(refusal)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Reel", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460)
        .onChange(of: text) { refusal = nil }
    }

    private func add() {
        if let message = model.addLink(text: text) {
            refusal = message
        } else {
            dismiss()
        }
    }
}
