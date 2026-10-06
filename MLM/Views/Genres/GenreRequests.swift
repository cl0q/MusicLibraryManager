import SwiftUI

/// Requests that reach the Genres place or the main window from elsewhere: File ▸ Export ▸
/// `Create ML Training Set…` opens the export sheet in the main window wherever the user is
/// (nothing navigates, P3); `Merge with Another Genre…` hands its genre to the list.
@MainActor
@Observable
final class GenreRequests {
    static let shared = GenreRequests()

    /// The export sheet (S-EXPORT) is shown.
    var showsExportSheet = false
    /// Genre keys the list selects when it appears next (`Merge with Another Genre…`).
    var listSelection: Set<String>?
}

extension View {
    /// Hosts the window-wide genre sheet (Export Create ML Training Set…). Applied once on the
    /// main window next to the playlist requests.
    func genreWindowRequests() -> some View {
        modifier(GenreWindowRequests())
    }
}

private struct GenreWindowRequests: ViewModifier {
    @Bindable private var requests = GenreRequests.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $requests.showsExportSheet) {
                CreateMLExportSheet()
            }
    }
}
