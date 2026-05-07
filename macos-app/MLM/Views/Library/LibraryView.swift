import SwiftUI

/// Library browser container — FilterBar + LibraryTable.
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────────────────────┐
/// │ [Local (423)] [Remote (87)]      🔍 Search   ⚙ Acts │  FilterBar
/// ├─────────────────────────────────────────────────────┤
/// │ Title     │ Artist │ Album  │ Fmt │ Dur │ ⚡ │ Added │  Table header
/// │ Song A    │ Art X  │ Alb 1  │ m4a │ 3:24│▃▅▇▅▃│ May 7│  Table rows
/// │ Song B    │ Art Y  │ Alb 2  │ flac│ 4:01│▃▅▅▃▁│ May 6│
/// │           │        │        │     │     │      │      │
/// └─────────────────────────────────────────────────────┘
/// ```
struct LibraryView: View {
    @Environment(\.container) private var container

    @State private var viewModel: LibraryViewModel?

    var body: some View {
        Group {
            if let viewModel {
                libraryContent(viewModel)
            } else {
                ProgressView("Initializing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            await viewModel?.loadTracks()
        }
    }

    // MARK: - Content

    private func libraryContent(_ viewModel: LibraryViewModel) -> some View {
        VStack(spacing: 0) {
            FilterBar(viewModel: viewModel)

            LibraryTable(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.mlmBase)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("\(viewModel.displayedTracks.count) tracks")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
        }
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository else { return }
        viewModel = LibraryViewModel(trackRepository: trackRepo)
    }
}
