import Foundation

// MARK: - The hand-off from a pasted link to quick add (DEC-018, UC-SEARCH-05)

/// The Add menu's sheets (W3-ADD, `ImportSheetsPresenter`): S-QUICKADD for a track or an
/// unsupported link, S-IMPORT at the preview step for a playlist link.
@MainActor
protocol QuickAddPresenting: AnyObject {
    /// Present S-QUICKADD (track) or S-IMPORT (playlist) for `link`. `lookup` is what the
    /// search field already knows about it (`nil` while it was still looking it up).
    func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?)
}

/// The one place a link goes — the search field's link row and Return on a link, a link
/// dropped or pasted on the window (`DropPerformer`). The main window installs its sheets as
/// `presenter` when it appears (`ImportSheetsHost`); W2-I's interim path (download directly,
/// open the remote-playlists window) is gone.
@MainActor
final class QuickAddRouter {
    static let shared = QuickAddRouter()

    /// The main window's sheets. Weak: the window owns them.
    weak var presenter: (any QuickAddPresenting)?

    /// `QuickAddRouter.open(url:)` — the seam named in the plan.
    func open(url: String, lookup: LinkLookup? = nil) {
        guard let link = LinkSuggestion.classify(url) else { return }
        open(link, lookup: lookup)
    }

    func open(_ link: LinkSuggestion, lookup: LinkLookup? = nil) {
        presenter?.presentQuickAdd(for: link, lookup: lookup)
    }
}
