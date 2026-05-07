import SwiftUI

/// Filter bar with Local/Remote tab switcher, search field, and action buttons.
///
/// Layout:
/// ```
/// [Local (423)] [Remote (87)]          🔍 Search ⌘F     ⚙ Actions
/// ```
struct FilterBar: View {
    @Bindable var viewModel: LibraryViewModel

    /// Whether the search field is focused.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: MLMSpacing.sectionGap) {
            // Local / Remote tab switcher
            tabSwitcher

            Spacer()

            // Search field
            searchField

            // Action buttons (placeholders for future phases)
            actionButtons
        }
        .padding(.horizontal, MLMSpacing.pagePadding)
        .frame(height: MLMSpacing.filterBarHeight)
        .background(Color.mlmSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.mlmEdgeSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Tab Switcher

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(LibraryTab.allCases) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.label)
                            .font(MLMFont.bodyBold)
                        Text("(\(countFor(tab)))")
                            .font(MLMFont.dataSmall)
                    }
                    .foregroundColor(viewModel.selectedTab == tab ? .mlmInk : .mlmInkMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: MLMSpacing.cornerRadiusSmall)
                            .fill(viewModel.selectedTab == tab ? Color.mlmRaised : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.mlmInkMuted)

            TextField("Search", text: $viewModel.searchQuery)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.mlmInkMuted)
                }
                .buttonStyle(.plain)
            }

            // ⌘F hint (only when not focused)
            if viewModel.searchQuery.isEmpty && !isSearchFocused {
                Text("⌘F")
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.mlmEdge, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: MLMSpacing.cornerRadiusSmall)
                .fill(Color.mlmRaised)
                .stroke(isSearchFocused ? Color.mlmAccent : Color.mlmEdge, lineWidth: 1)
        )
        .onKeyPress(.init("f"), modifiers: .command) {
            isSearchFocused = true
            return .handled
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            // Placeholder buttons for future phases (Analyze, Match, Filters)
            actionButton(icon: "waveform", tooltip: "Analyze")
            actionButton(icon: "arrow.triangle.branch", tooltip: "Match")
            actionButton(icon: "line.3.horizontal.decrease", tooltip: "Filters")
        }
    }

    private func actionButton(icon: String, tooltip: String) -> some View {
        Button {
            // Placeholder — wired in future phases
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.mlmInkMuted)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Helpers

    private func countFor(_ tab: LibraryTab) -> Int {
        switch tab {
        case .local: viewModel.localCount
        case .remote: viewModel.remoteCount
        }
    }
}
