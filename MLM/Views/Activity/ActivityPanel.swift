import SwiftUI
import AppKit

/// Collapsible activity panel at the bottom of the window.
///
/// Shows a 36pt header bar with a composite summary driven by `ActivityFeed`.
/// Expands to reveal Operations and Logs tabs. Panel state (expansion, height,
/// selected tab) is persisted via `@AppStorage`.
struct ActivityPanel: View {

    @AppStorage("activity.panel.expanded") private var isExpanded: Bool = false
    @AppStorage("activity.panel.height") private var panelHeight: Double = 284
    @AppStorage("activity.selectedTab") private var selectedTabRaw: String = "Operations"

    @Environment(\.container) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragBaseHeight: CGFloat = 284

    private var selectedTab: Binding<ActivityTab> {
        Binding(
            get: { ActivityTab(rawValue: selectedTabRaw) ?? .operations },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    enum ActivityTab: String, CaseIterable {
        case operations = "Operations"
        case logs = "Logs"
    }

    var body: some View {
        VStack(spacing: 0) {
            activityHeader

            if isExpanded {
                ResizeHandle(panelHeight: $panelHeight, dragBaseHeight: $dragBaseHeight)
                activityContent
            }
        }
        .background(Color.mlmSurface)
        .clipped()
        .accessibilityIdentifier("activity_panel")
        .background(
            Button("") {
                collapsePanel()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    // MARK: - Header

    private var activityHeader: some View {
        Button {
            toggleExpanded()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.mlmInkMuted)
                    .frame(width: 12)
                    .accessibilityIdentifier("activity_header_chevron")

                Text("Activity")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkSecondary)

                Spacer()

                summarySection
                    .accessibilityIdentifier("activity_header_summary")
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity_header")
    }

    // MARK: - Composite summary (headline from ActivityFeed)

    @ViewBuilder
    private var summarySection: some View {
        let snapshot = currentSnapshot()
        let headline = snapshot.headline

        HStack(spacing: 6) {
            if headline.isBusy {
                ProgressView()
                    .controlSize(.mini)
            }

            Text(headline.text)
                .font(MLMFont.muted)
                .foregroundColor(headline.isEmpty ? .mlmInkMuted : .mlmInkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(headline.tooltip)
    }

    private func currentSnapshot() -> ActivityFeedSnapshot {
        guard let vm = container.activityViewModel else {
            return ActivityFeedSnapshot(
                sections: [],
                headline: ActivityHeadline(
                    text: "No active operations",
                    tooltip: "No active operations",
                    isBusy: false,
                    isEmpty: true
                ),
                isEmpty: true
            )
        }

        let downloadState: DownloadSourceState? = container.downloadViewModel.map {
            $0.sourceState(operationID: nil)
        }

        let queueService = PerformanceQueueService.shared
        let queueState = QueueSourceState(
            activeJobDescription: queueService.activeJobDescription,
            pendingAnalyses: queueService.pendingAnalysesCount,
            pendingDownloads: queueService.pendingDownloadsCount
        )

        return ActivityFeed.makeSnapshot(
            operations: vm.operations,
            stalledIDs: vm.stalledOperationIDs,
            recentOperations: vm.recentOperations,
            recentTruncated: vm.isRecentTruncated,
            download: downloadState,
            sync: nil,
            queue: queueState,
            persistedFailures: [],
            now: Date()
        )
    }

    // MARK: - Expanded content

    private var activityContent: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.mlmEdgeSubtle)

            Picker("Tab", selection: selectedTab) {
                ForEach(ActivityTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("activity_tab_picker")

            Group {
                switch selectedTab.wrappedValue {
                case .operations:
                    OperationsTab()
                case .logs:
                    LogsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: CGFloat(panelHeight))
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity)
        )
    }

    // MARK: - Actions

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        if !isExpanded == false {
            dragBaseHeight = CGFloat(panelHeight)
        }
    }

    private func collapsePanel() {
        guard isExpanded else { return }
        if reduceMotion {
            isExpanded = false
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = false
            }
        }
    }
}

// MARK: - Resize Handle

/// A dedicated drag handle for resizing the panel. Placed between the header
/// and the content so it does not overlap the collapse button.
private struct ResizeHandle: View {
    @Binding var panelHeight: Double
    @Binding var dragBaseHeight: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.mlmEdgeSubtle.opacity(0.5))
            .frame(height: 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newHeight = dragBaseHeight - value.translation.height
                        panelHeight = Double(Swift.min(Swift.max(newHeight, 150), 700))
                    }
                    .onEnded { _ in
                        dragBaseHeight = CGFloat(panelHeight)
                    }
            )
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityIdentifier("activity_resize_handle")
    }
}
