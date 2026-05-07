import SwiftUI

/// Collapsible activity panel at the bottom of the window.
///
/// Shows a 36px header bar when collapsed. Expands to reveal
/// Operations and Logs tabs. Phase 16 wires in real operation
/// tracking and log streaming.
struct ActivityPanel: View {
    @State private var isExpanded = false
    @State private var selectedTab: ActivityTab = .operations

    enum ActivityTab: String, CaseIterable {
        case operations = "Operations"
        case logs = "Logs"
    }

    var body: some View {
        VStack(spacing: 0) {
            activityHeader

            if isExpanded {
                activityContent
            }
        }
        .background(Color.mlmSurface)
        .clipped()
    }

    // MARK: - Header

    private var activityHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.mlmInkMuted)
                    .frame(width: 12)

                Text("Activity")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkSecondary)

                Spacer()

                // Summary text — wired to real data in Phase 16
                Text("No active operations")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
            .padding(.horizontal, MLMSpacing.pagePadding)
            .frame(height: MLMSpacing.activityCollapsed)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded content

    private var activityContent: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.mlmEdgeSubtle)

            Picker("Tab", selection: $selectedTab) {
                ForEach(ActivityTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, MLMSpacing.pagePadding)
            .padding(.vertical, 8)

            Group {
                switch selectedTab {
                case .operations:
                    OperationsTab()
                case .logs:
                    LogsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: MLMSpacing.activityExpanded - MLMSpacing.activityCollapsed)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
