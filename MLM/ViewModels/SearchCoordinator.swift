import Foundation

/// Coordinates the single toolbar search entry point across all detail contexts.
///
/// The toolbar `TextField` binds to `query`. Each context decides whether
/// typing live-filters a local table (library, playlist detail) or opens
/// the global search pane (other sections). Return / submit always opens
/// the global search pane.
///
/// IMPORTANT: The toolbar search bar is for LOCAL LIBRARY search only.
/// URL-based / remote / universal search lives in `UniversalSearchView`,
/// opened via a separate toolbar button.
@Observable
final class SearchCoordinator {

    // MARK: - Search context

    /// Which detail pane is currently visible — drives whether typing
    /// live-filters a local table or opens the global search pane.
    enum SearchContext: Equatable {
        case library
        case playlist(Int64)
        case other
    }

    // MARK: - State

    /// The current search query bound to the toolbar TextField.
    var query: String = ""

    /// Whether the global search pane is presented in the detail area.
    private(set) var isPresented: Bool = false

    /// The current navigation context — updated by ContentView on section change.
    var context: SearchContext = .library

    // MARK: - Actions

    /// Return was pressed — always open the global search pane.
    func submit() {
        isPresented = true
    }

    /// Dismiss the global search pane.
    func dismiss() {
        isPresented = false
    }

    /// Called when the query text changes.
    ///
    /// - Parameter hasLocalTable: `true` when the current section has its own
    ///   table that live-filters (library, playlist detail). In that case the
    ///   coordinator does NOT present the global pane — the view pushes the
    ///   query into its view model instead.
    func queryChanged(hasLocalTable: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasLocalTable && !trimmed.isEmpty {
            isPresented = true
        }
    }
}
