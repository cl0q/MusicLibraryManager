import AppKit
import SwiftUI

/// Collapsible activity panel at the bottom of the window.
///
/// Shows a 36px header bar when collapsed. Expands to reveal
/// Operations and Logs tabs. Wired to ActivityViewModel and AppLogger.
struct ActivityPanel: View {
    @State private var isExpanded = false
    @State private var selectedTab: ActivityTab = .operations
    @Environment(\.container) private var container

    @State private var expandedHeight: CGFloat = 284
    @State private var baseHeight: CGFloat = 284

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
        .overlay(
            Group {
                if isExpanded {
                    Color.clear
                        .frame(height: 6)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newHeight = baseHeight - value.translation.height
                                    expandedHeight = min(max(newHeight, 150), 700)
                                }
                                .onEnded { value in
                                    baseHeight = expandedHeight
                                }
                        )
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            },
            alignment: .top
        )
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

                summarySection
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Right-aligned summary in the collapsed header. Downloads take
    /// priority over generic operations so the user can see batch progress
    /// without expanding the panel.
    @ViewBuilder
    private var summarySection: some View {
        if let downloadVM = container.downloadViewModel, downloadVM.isDownloading {
            ProgressView()
                .controlSize(.mini)
                .padding(.trailing, 4)
            Text(downloadSummary(for: downloadVM))
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let activeDesc = PerformanceQueueService.shared.activeJobDescription {
            ProgressView()
                .controlSize(.mini)
                .padding(.trailing, 4)
            Text("\(activeDesc) (\(PerformanceQueueService.shared.pendingAnalysesCount) pending)")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let vm = container.activityViewModel {
            if vm.hasActiveOperations {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 4)
            }
            Text(vm.summaryText)
                .font(MLMFont.muted)
                .foregroundColor(vm.hasActiveOperations ? .mlmInkPrimary : .mlmInkMuted)
        } else {
            Text("No active operations")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
    }

    private func downloadSummary(for vm: DownloadViewModel) -> String {
        let completed = vm.completedCount + 1  // +1 to show 1-based count of current
        let total = vm.totalCount
        if vm.currentTrack.isEmpty {
            return "Downloading \(min(completed, total)) / \(total)"
        }
        return "Downloading \(min(completed, total)) / \(total) — \(vm.currentTrack)"
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
            .padding(.horizontal, 16)
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
        .frame(height: expandedHeight)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
