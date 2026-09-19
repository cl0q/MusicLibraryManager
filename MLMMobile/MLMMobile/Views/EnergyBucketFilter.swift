import SwiftUI

/// Horizontal filter chips for energy buckets 1-5.
struct EnergyBucketFilter: View {
    @Binding var selected: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(1...5, id: \.self) { bucket in
                    FilterChip(
                        label: "E\(bucket)",
                        isSelected: selected == bucket
                    ) {
                        selected = (selected == bucket) ? nil : bucket
                    }
                }
            }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
