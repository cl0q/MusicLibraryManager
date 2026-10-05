import Foundation

/// The committed state of the one toolbar search field, shared by the views that apply it
/// (DEC-017, UC-SEARCH-01/02/06):
///
/// - **One filter per place.** The query belongs to the view: every place keeps the filter it
///   was given for the session (`filters[key]`), so leaving a view and coming back restores it.
///   A view reads only its own: `filter(for: .allTracks)`, `filter(for: .playlist(id))`.
/// - **The scope.** `This view` filters the visible place in place. `Library` and `Online`
///   show their results over the place (`isPresented`) — only on request (the scope bar,
///   ⌥⌘F, the escalation buttons), never by typing or Return.
///
/// The per-keystroke text lives in the window's `ToolbarSearchModel`, which commits here
/// (debounced). Nothing here ever writes to the library.
@Observable
final class SearchCoordinator {
    /// Committed filters per place (only non-empty ones are kept).
    private(set) var filters: [SearchPlaceKey: SearchFilter] = [:]

    /// The scope chosen in the scope bar.
    private(set) var scope: SearchScope = .thisView

    /// The place the field currently belongs to.
    private(set) var activePlace: SearchPlace = .allTracks

    /// Bumped by Return in the field: the Online scope asks its sources now instead of after
    /// the typing pause.
    private(set) var submitCount = 0

    /// Whether the results of a wider scope (`Library`, `Online`) are shown over the place.
    /// The place's own table is then hidden: its menus and selection bar step back.
    var isPresented: Bool { scope != .thisView }

    /// The filter committed for `key` (empty when none).
    func filter(for key: SearchPlaceKey) -> SearchFilter {
        filters[key] ?? .empty
    }

    /// The filter of the place the field belongs to (what `Library` / `Online` search with).
    var activeFilter: SearchFilter { filter(for: activePlace.key) }

    func commit(_ filter: SearchFilter, for key: SearchPlaceKey) {
        let stored: SearchFilter? = filter.hasInput ? filter : nil
        guard filters[key] != stored else { return }
        filters[key] = stored
    }

    func setScope(_ scope: SearchScope) {
        guard self.scope != scope else { return }
        self.scope = scope
    }

    func setActivePlace(_ place: SearchPlace) {
        guard activePlace != place else { return }
        activePlace = place
    }

    func noteSubmit() {
        submitCount += 1
    }
}
