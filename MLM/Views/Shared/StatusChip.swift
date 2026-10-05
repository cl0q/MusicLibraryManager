import SwiftUI

/// A text-labeled status: `.secondary` words plus an SF Symbol, the symbol tinted only for
/// "needs action" / error states (UC-COLOR-05). No capsule, no fill (N3). The track table's
/// Status column uses `TrackStatusLabel`; this stays for the other places that show a
/// state word (playlist header, cards, Folders).
@MainActor
struct StatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color?

    /// - Parameter tint: the symbol's tint (system orange / red / green), `nil` = `.secondary`.
    init(text: String, systemImage: String, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    /// Returns no chip for the default local state.
    init?(availability: TrackAvailability) {
        guard let status = TrackStatusDisplay.forAvailability(availability) else { return nil }
        let tint: Color? = switch status.tint {
        case .none: nil
        case .attention: .orange
        case .error: .red
        }
        self.init(text: status.text, systemImage: status.systemImage, tint: tint)
    }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status_chip")
        .accessibilityLabel(text)
    }
}
