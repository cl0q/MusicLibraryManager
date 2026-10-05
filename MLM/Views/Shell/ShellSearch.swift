import Observation
import SwiftUI

/// The toolbar search field's state, moved from the old hand-built `GlobalSearchField` to the
/// system `.searchable` field (UC-SEARCH-01). The search *logic* is unchanged and still lives
/// in `SearchCoordinator` (rebuilt by W2-I):
///
/// - typing commits the query after a 100 ms debounce, then `queryChanged(hasLocalTable:)`
///   either filters the visible table (All Tracks, playlists) or opens the search pane;
/// - Return commits at once and opens the search pane (`submit()`);
/// - clearing the field (its clear button, Esc, or deleting the text) resets the query and
///   dismisses the pane;
/// - switching places resets everything (`reset()`).
///
/// Per-keystroke state stays in this object so typing doesn't re-render the window content.
@MainActor
@Observable
final class ToolbarSearchModel {
    /// The field's text.
    var text = "" {
        didSet {
            guard text != oldValue, !isMirroring else { return }
            textDidChange()
        }
    }

    /// Whether the field has focus (⌘F sets it).
    var isPresented = false

    /// Whether the visible place filters its own table instead of opening the search pane.
    @ObservationIgnored var hasLocalTable: @MainActor () -> Bool = { false }

    @ObservationIgnored private let coordinator: SearchCoordinator
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isMirroring = false

    static let debounce: Duration = .milliseconds(100)

    init(coordinator: SearchCoordinator) {
        self.coordinator = coordinator
    }

    /// Return in the field.
    func submit() {
        debounceTask?.cancel()
        if text != coordinator.query {
            commit()
        }
        coordinator.submit()
    }

    /// Leave search entirely (place changed, or the search pane's own Exit).
    func reset() {
        debounceTask?.cancel()
        mirror("")
        coordinator.dismiss()
        coordinator.query = ""
        isPresented = false
    }

    /// Follow a query changed elsewhere (e.g. inside the search pane).
    func mirror(_ query: String) {
        guard text != query else { return }
        isMirroring = true
        text = query
        isMirroring = false
    }

    private func textDidChange() {
        debounceTask?.cancel()
        if text.isEmpty {
            coordinator.dismiss()
            coordinator.query = ""
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            if self.text != self.coordinator.query {
                self.commit()
            }
        }
    }

    private func commit() {
        coordinator.query = text
        coordinator.queryChanged(hasLocalTable: hasLocalTable())
    }
}

/// Attaches the system search field to the shell (UC-SEARCH-01). Isolated in its own view so
/// keystrokes only re-render this wrapper.
struct SearchableShell<Content: View>: View {
    @Bindable var model: ToolbarSearchModel
    let content: Content

    init(model: ToolbarSearchModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content
            .searchable(text: $model.text, isPresented: $model.isPresented, placement: .toolbar, prompt: Text("Search"))
            .onSubmit(of: .search) {
                model.submit()
            }
            .background {
                SearchQueryMirror(model: model)
            }
    }
}

/// Mirrors `SearchCoordinator.query` changes made elsewhere back into the field.
private struct SearchQueryMirror: View {
    let model: ToolbarSearchModel
    @Environment(\.container) private var container

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: container.searchCoordinator.query) { _, query in
                model.mirror(query)
            }
            .accessibilityHidden(true)
    }
}
