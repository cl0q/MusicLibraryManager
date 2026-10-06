import AppKit
import SwiftUI

// MARK: - The Add menu's sheets on the main window (P-ADDMENU, S-QUICKADD, S-IMPORT)

extension View {
    /// Presents `presenter`'s sheets over the main window and makes it the search field's
    /// `QuickAddPresenting` (links from the search field, drops and pastes land here).
    func importSheets(_ presenter: ImportSheetsPresenter, search: ToolbarSearchModel) -> some View {
        modifier(ImportSheetsHost(presenter: presenter, search: search))
    }
}

private struct ImportSheetsHost: ViewModifier {
    @Bindable var presenter: ImportSheetsPresenter
    let search: ToolbarSearchModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.sheet) { sheet in
                switch sheet {
                case .quickAdd(let model): QuickAddSheet(model: model)
                case .importPlaylist(let model): ImportPlaylistSheet(model: model)
                }
            }
            .onAppear {
                QuickAddRouter.shared.presenter = presenter
                presenter.openSettingsSources = { openSettings(tab: .sources) }
                let search = self.search
                presenter.revealTrack = { [weak search] id in
                    if let search { SearchReveal.showInAllTracks(id, search: search) }
                }
                Task { await presenter.reloadAccounts() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Accounts may have changed in Settings or the browser meanwhile.
                Task { await presenter.reloadAccounts() }
            }
    }
}
