import Observation
import SwiftUI

/// The toolbar search field of one main window (V-SEARCH, DEC-017/018, UC-SEARCH-01…07).
///
/// One behaviour: the text and tokens **always filter the current view in place**. The scope
/// bar (`This view · Library · Online`) widens the search only when the user asks; typing and
/// Return never open another surface.
///
/// - Typing commits the filter to `SearchCoordinator` for the visible place after a 100 ms
///   debounce (`debounce`, injectable sleep). Clearing the field (its ✕, Esc, deleting) commits
///   at once and returns the scope to `This view`.
/// - The query belongs to the view: `placeDidChange()` keeps the outgoing place's filter and
///   restores the incoming place's (for the session).
/// - Return (`submit()`): a link → its action (`QuickAddRouter`); a filter word being typed →
///   its first value becomes a token; otherwise focus moves to the filtered rows
///   (`moveFocusToResults`) — or, in `Online`, the sources are asked at once.
/// - Suggestions: recent searches and filter words in the empty field, library values after
///   a filter word, the link row for a URL (`SearchSuggestionList`).
///
/// Per-keystroke state stays in this object, so typing doesn't re-render the window content.
@MainActor
@Observable
final class ToolbarSearchModel {
    /// The field's text.
    var text = "" {
        didSet {
            guard text != oldValue, !isLoadingPlace else { return }
            inputDidChange()
        }
    }

    /// Tokens inside the field (`genre: Techno`).
    var tokens: [SearchToken] = [] {
        didSet {
            guard tokens != oldValue, !isLoadingPlace else { return }
            tokensDidChange(from: oldValue)
        }
    }

    /// Whether the field is active (⌘F / ⌥⌘F set it).
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            if isPresented {
                refreshRecents()
            } else {
                recordRecent()
            }
        }
    }

    /// The scope bar's choice. `This view` each time search starts and after clearing.
    var scope: SearchScope = .thisView {
        didSet {
            guard scope != oldValue else { return }
            coordinator.setScope(scope)
        }
    }

    /// The place the field belongs to.
    private(set) var place: SearchPlace = .allTracks

    /// Library values for the filter word being typed (`suggestionsClause`).
    private(set) var valueSuggestions: [SearchValueSuggestion] = []
    private(set) var suggestionsClause: SearchTrailingClause?
    /// The pasted link, when the text is one.
    private(set) var link: LinkSuggestion?
    /// What the link is; `nil` while it is being looked up.
    private(set) var linkLookup: LinkLookup?
    private(set) var recentSearches: [RecentSearch] = []

    // MARK: Dependencies

    @ObservationIgnored let coordinator: SearchCoordinator
    /// The visible place (from the window's navigation).
    @ObservationIgnored var placeProvider: @MainActor () -> SearchPlace = { .allTracks }
    @ObservationIgnored weak var navigation: NavigationModel?
    @ObservationIgnored var suggestionProvider: (any SearchSuggestionProviding)?
    @ObservationIgnored var recentStore: RecentSearchStore?
    /// Return with nothing to confirm: focus the filtered rows.
    @ObservationIgnored var moveFocusToResults: @MainActor () -> Void = {}
    /// Return / the link row: the link's action (`QuickAddRouter.open(url:)`).
    @ObservationIgnored var openLink: @MainActor (LinkSuggestion) -> Void = { _ in }
    /// One status-bar line when the visible place can't apply what was typed.
    @ObservationIgnored var postHint: @MainActor (String) -> Void = { _ in }

    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// The pending debounced commit (exposed for tests).
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    @ObservationIgnored private(set) var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var linkTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingPlace = false
    @ObservationIgnored private var lastHint: String?

    static let debounce: Duration = .milliseconds(100)

    /// - Parameter sleep: suspends for a duration; injectable so tests control the debounce.
    init(
        coordinator: SearchCoordinator,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.coordinator = coordinator
        self.sleep = sleep
    }

    // MARK: Reading

    var filter: SearchFilter { SearchFilter(text: text, tokens: tokens) }

    var hasInput: Bool { filter.hasInput }

    /// The filter word being typed at the end of the text (not for links).
    var trailingClause: SearchTrailingClause? {
        link == nil ? SearchQueryParser.parse(text).trailing : nil
    }

    /// Filter words offered in this scope: every kind in `Library`, the place's in `This view`,
    /// none `Online` (sources know no tokens).
    var offeredKinds: [SearchTokenKind] {
        switch scope {
        case .thisView: place.offeredKinds
        case .library: SearchTokenKind.allCases
        case .online: []
        }
    }

    /// Filter words the last typed word starts (`gen` → `genre:`), with the text each one
    /// completes to.
    var keywordCompletions: [(kind: SearchTokenKind, completion: String)] {
        guard link == nil, !text.isEmpty, text.last?.isWhitespace == false else { return [] }
        let parsed = SearchQueryParser.parse(text)
        guard parsed.trailing == nil, let last = text.split(whereSeparator: \.isWhitespace).last,
              !last.contains(":") else { return [] }
        let word = last.lowercased()
        let before = String(text.dropLast(last.count))
        return offeredKinds
            .filter { $0.keyword.hasPrefix(word) && $0.keyword != word }
            .map { ($0, "\(before)\($0.prefix) ") }
    }

    // MARK: Commands

    /// Return in the field (K-SEARCH-RETURN, UC-SEARCH-06).
    func submit() {
        debounceTask?.cancel()
        if let link {
            openLink(link)
            return
        }
        if let clause = trailingClause, clause == suggestionsClause, let first = valueSuggestions.first {
            accept(first.token)
            return
        }
        commit()
        recordRecent()
        coordinator.noteSubmit()
        if scope == .thisView {
            moveFocusToResults()
        }
    }

    /// A value suggestion was chosen: it becomes a token; the typed clause leaves the text.
    func accept(_ token: SearchToken) {
        guard !tokens.contains(where: { $0.id == token.id }) else {
            stripTrailingClause()
            return
        }
        tokens.append(token)
    }

    /// ⌘F (`This view`) / ⌥⌘F (`Library`): focus the field in that scope.
    func focus(scope: SearchScope) {
        syncPlace()
        self.scope = scope
        isPresented = true
    }

    /// Clear text and tokens; the scope returns to `This view` (Esc, `Clear Filters`).
    func clear() {
        debounceTask?.cancel()
        isLoadingPlace = true
        text = ""
        tokens = []
        isLoadingPlace = false
        inputDidChange()
    }

    /// Leave search for the visible place (Go to Current Track): its filter is cleared so the
    /// row can show.
    func reset() {
        syncPlace()
        clear()
        isPresented = false
    }

    /// The visible place changed: keep the outgoing place's filter, restore the incoming one's
    /// (UC-SEARCH-06). The scope returns to `This view`.
    func placeDidChange() {
        syncPlace()
    }

    /// A recent search was chosen.
    func apply(_ recent: RecentSearch) {
        isLoadingPlace = true
        tokens = recent.tokens
        text = recent.text
        isLoadingPlace = false
        inputDidChange()
    }

    /// Show `filter` in a destination's own list, in place (`Show All`, Go to Artist).
    func show(_ filter: SearchFilter, in destination: SidebarDestination) {
        debounceTask?.cancel()
        commit()
        guard let navigation else { return }
        let target = SearchPlace.root(of: destination)
        coordinator.commit(filter, for: target)
        scope = .thisView
        navigation.select(destination)
        if navigation.selection == destination, !navigation.path.isEmpty {
            navigation.popToRoot()
        }
        if placeProvider().key == place.key {
            // Already the place the field belongs to: show the new filter in the field.
            load(filter)
        }
        syncPlace()
    }

    private func load(_ filter: SearchFilter) {
        isLoadingPlace = true
        text = filter.text
        tokens = filter.tokens
        isLoadingPlace = false
        updateLink()
    }

    /// Track ▸ Go to Artist: All Tracks with the token `artist: ‹name›` (exact).
    func goToArtist(_ name: String) {
        show(SearchFilter(tokens: [.artist(name)]), in: .allTracks)
    }

    // MARK: Changes

    private func syncPlace() {
        let new = placeProvider()
        guard new.key != place.key else {
            if new != place {
                place = new
                coordinator.setActivePlace(new)
            }
            return
        }
        debounceTask?.cancel()
        commit()
        recordRecent()
        place = new
        coordinator.setActivePlace(new)
        load(coordinator.filter(for: new.key))
        lastHint = nil
        valueSuggestions = []
        suggestionsClause = nil
        scope = .thisView
    }

    private func tokensDidChange(from old: [SearchToken]) {
        if tokens.count > old.count {
            stripTrailingClause()
        }
        inputDidChange()
    }

    /// A chosen token replaces the clause that was typed for it.
    private func stripTrailingClause() {
        guard let clause = SearchQueryParser.parse(text).trailing else { return }
        let before = clause.textBefore
        text = before.isEmpty ? "" : before + " "
    }

    private func inputDidChange() {
        updateLink()
        debounceTask?.cancel()
        guard hasInput else {
            commit()
            valueSuggestions = []
            suggestionsClause = nil
            scope = .thisView
            refreshRecents()
            return
        }
        let sleep = self.sleep
        debounceTask = Task { [weak self] in
            do {
                try await sleep(Self.debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.commit()
            self.loadValueSuggestions()
        }
    }

    private func commit() {
        coordinator.commit(filter, for: place.key)
        hintIfIgnored()
    }

    /// One status-bar line when the visible place can't apply the tokens (or can't filter).
    private func hintIfIgnored() {
        guard scope == .thisView else { return }
        let current = filter
        guard current.hasInput, !current.isLink else { return }
        var message: String?
        switch place.capability {
        case .tracks:
            break
        case .names:
            let ignored = current.ignoredTokens(for: .names)
            if !ignored.isEmpty {
                let list = ignored.map { "“\($0.displayText)”" }.joined(separator: ", ")
                message = "\(place.name) filters by name only — \(list) isn’t applied here"
            }
        case .none:
            message = "\(place.name) can’t be filtered — choose Library to search everywhere"
        }
        guard let message, message != lastHint else { return }
        lastHint = message
        postHint(message)
    }

    private func loadValueSuggestions() {
        suggestionTask?.cancel()
        guard let clause = trailingClause, offeredKinds.contains(clause.kind), let provider = suggestionProvider else {
            valueSuggestions = []
            suggestionsClause = nil
            return
        }
        suggestionTask = Task { [weak self] in
            let values = await provider.values(kind: clause.kind, partial: clause.partialValue)
            guard !Task.isCancelled, let self, self.trailingClause == clause else { return }
            self.valueSuggestions = values
            self.suggestionsClause = clause
        }
    }

    private func updateLink() {
        let new = tokens.isEmpty ? LinkSuggestion.classify(text) : nil
        guard new != link else { return }
        link = new
        linkLookup = nil
        linkTask?.cancel()
        guard let new else { return }
        guard let provider = suggestionProvider else {
            linkLookup = LinkLookup()
            return
        }
        linkTask = Task { [weak self] in
            let lookup = await provider.lookUp(new)
            guard !Task.isCancelled, let self, self.link == new else { return }
            self.linkLookup = lookup
        }
    }

    private func recordRecent() {
        let current = coordinator.filter(for: place.key)
        guard current.hasInput, !current.isLink, let recentStore else { return }
        recentSearches = recentStore.record(current)
    }

    private func refreshRecents() {
        recentSearches = recentStore?.load() ?? []
    }
}

extension SearchPlace {
    /// The key of a sidebar destination's root list (Show All targets).
    static func root(of destination: SidebarDestination) -> SearchPlaceKey {
        switch destination {
        case .allTracks: .allTracks
        case .allPlaylists: .allPlaylists
        case .folders: .folders
        case .review: .review
        case .discover: .discover
        case .playlist(let id): .playlist(id)
        case .albums: SearchPlaceKey("albums")
        case .genres: SearchPlaceKey("genres")
        case .syncProfile(let id): SearchPlaceKey("syncProfile.\(id)")
        }
    }
}

/// Attaches the system search field to the shell (UC-SEARCH-01, UC-KIT-07): `.searchable`
/// with tokens in the toolbar, `.searchScopes` shown while searching (UC-SEARCH-02,
/// UC-LAYOUT-03) and `.searchSuggestions`. Isolated in its own view so keystrokes only
/// re-render this wrapper.
struct SearchableShell<Content: View>: View {
    @Bindable var model: ToolbarSearchModel
    let content: Content

    init(model: ToolbarSearchModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content
            .searchable(
                text: $model.text,
                tokens: $model.tokens,
                isPresented: $model.isPresented,
                placement: .toolbar,
                prompt: Text("Search")
            ) { token in
                Text(token.displayText)
            }
            .searchScopes($model.scope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .searchSuggestions {
                SearchSuggestionList(model: model)
            }
            .onSubmit(of: .search) {
                model.submit()
            }
    }
}
