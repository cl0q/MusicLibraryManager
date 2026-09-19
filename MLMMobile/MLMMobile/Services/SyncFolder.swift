import Foundation
import SwiftUI

/// Locates and observes the MLM sync folder on the device.
///
/// Transport-agnostic per IOS_SIDECAR_PLAN.md §5: the folder may come from
/// (a) iCloud Drive, (b) a security-scoped bookmark from the document picker
///     (covers SMB shares connected through Files), or
/// (c) files imported into the app's Documents directory.
///
/// The chosen folder's bookmark is persisted in UserDefaults so it survives launches.
@MainActor
final class SyncFolder: ObservableObject {
    @Published var rootURL: URL?
    @Published var hasError = false
    @Published var errorMessage: String?

    private let bookmarkKey = "MLMMobile.syncFolderBookmark"
    private let fileManager = FileManager.default

    /// The manifest file URL within the sync folder.
    var manifestURL: URL? {
        rootURL?.appendingPathComponent("mlm-library.json")
    }

    /// The playlists directory within the sync folder.
    var playlistsDirectory: URL? {
        rootURL?.appendingPathComponent("Playlists", isDirectory: true)
    }

    /// The music root within the sync folder.
    var musicRoot: URL? {
        rootURL?.appendingPathComponent("Music", isDirectory: true)
    }

    init() {
        restoreBookmark()
    }

    // MARK: - Public API

    /// Set the sync folder from a security-scoped URL (e.g. from a document picker).
    /// Persists a security-scoped bookmark for future launches.
    func setFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            rootURL = url
            hasError = false
            errorMessage = nil
        } catch {
            hasError = true
            errorMessage = "Failed to bookmark folder: \(error.localizedDescription)"
        }
    }

    /// Use the app's Documents directory as the sync folder (for files imported via Files app).
    func useDocumentsDirectory() {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            hasError = true
            errorMessage = "Could not locate Documents directory"
            return
        }
        rootURL = docs
        // Clear any stored bookmark since Documents is always available.
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        hasError = false
        errorMessage = nil
    }

    /// Clear the stored folder selection.
    func clearFolder() {
        rootURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        hasError = false
        errorMessage = nil
    }

    // MARK: - Private

    private func restoreBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            // No bookmark stored — try Documents directory as fallback.
            if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
               fileManager.fileExists(atPath: docs.appendingPathComponent("mlm-library.json").path) {
                rootURL = docs
            }
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Re-bookmark the resolved URL.
                setFolder(url)
            } else {
                _ = url.startAccessingSecurityScopedResource()
                rootURL = url
            }
        } catch {
            hasError = true
            errorMessage = "Stored folder no longer accessible: \(error.localizedDescription)"
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }
}
