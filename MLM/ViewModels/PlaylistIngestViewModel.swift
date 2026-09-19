import Foundation
import SwiftUI

/// ViewModel for the m3u8 ingest flow (WP4).
///
/// Owns the preview state machine: load file → preview populated → apply/cancel.
/// Used by both PlaylistDetailView (Trigger A: file import) and SyncView
/// (Trigger B: device scan).
///
/// Decision logic lives here so it's testable without UI.
@Observable
final class PlaylistIngestViewModel {

    // MARK: - State

    /// The current preview, populated after `loadPreview(url:profileId:)`.
    private(set) var preview: IngestPreview?

    /// The source file name (for display in the sheet).
    private(set) var sourceFileName: String?

    /// Whether an apply operation is in progress.
    private(set) var isApplying = false

    /// Error from the last failed operation (preview or apply).
    private(set) var errorMessage: String?

    /// Whether the last apply succeeded (for showing success feedback).
    private(set) var didApplySuccessfully = false

    // MARK: - Dependencies

    private let ingestService: PlaylistIngestService

    // MARK: - Init

    init(ingestService: PlaylistIngestService) {
        self.ingestService = ingestService
    }

    // MARK: - Preview State Machine

    /// Load a preview for the given m3u8 file URL.
    ///
    /// - Parameters:
    ///   - url: URL of the m3u8 file
    ///   - profileId: Optional sync profile ID. Pass nil for standalone imports
    ///     (the engine uses -1 as sentinel, resulting in "diff against empty snapshot"
    ///     which produces append-only behavior per spec §4).
    @MainActor
    func loadPreview(url: URL, profileId: Int64? = nil) async {
        errorMessage = nil
        didApplySuccessfully = false
        preview = nil
        sourceFileName = url.lastPathComponent

        do {
            let ingestedPreview = try await ingestService.preview(url: url, profileId: profileId)
            preview = ingestedPreview
        } catch {
            errorMessage = "Failed to load preview: \(error.localizedDescription)"
        }
    }

    /// Apply the current preview.
    ///
    /// Calls the engine's ingest path (re-parses + applies atomically).
    /// Returns the target playlist ID on success.
    @MainActor
    func apply(url: URL, profileId: Int64) async -> Int64? {
        guard preview != nil else { return nil }

        isApplying = true
        errorMessage = nil
        didApplySuccessfully = false

        do {
            let result = try await ingestService.ingest(url: url, profileId: profileId)
            didApplySuccessfully = true
            isApplying = false
            return result.playlistId
        } catch {
            errorMessage = "Failed to apply: \(error.localizedDescription)"
            isApplying = false
            return nil
        }
    }

    /// Cancel the current preview (clear state).
    @MainActor
    func cancel() {
        preview = nil
        sourceFileName = nil
        errorMessage = nil
        didApplySuccessfully = false
    }

    /// Clear any error message.
    @MainActor
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Device Scan (Trigger B)

    /// Scan a profile's output folder for m3u8 files and build previews.
    ///
    /// Returns an array of (fileName, preview) pairs for files that have changes.
    /// Files with empty previews (no diff) are excluded.
    ///
    /// - Parameter profile: The sync profile to scan.
    /// - Returns: Array of (fileName, preview) for changed files.
    @MainActor
    func scanProfileForChanges(profile: SyncProfile) async -> [(fileName: String, preview: IngestPreview)] {
        guard let profileId = profile.id else { return [] }

        let outputFolder = profile.outputFolder
        guard FileManager.default.fileExists(atPath: outputFolder) else {
            errorMessage = "Device not connected — output folder not found"
            return []
        }

        // Find all .m3u8 files in the output folder (recursively)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: outputFolder) else {
            return []
        }

        var results: [(fileName: String, preview: IngestPreview)] = []

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".m3u8") else { continue }
            let fullPath = (outputFolder as NSString).appendingPathComponent(relativePath)
            let url = URL(fileURLWithPath: fullPath)

            do {
                let ingestedPreview = try await ingestService.preview(url: url, profileId: profileId)
                // Only include files that have actual changes
                if !ingestedPreview.isEmpty || !ingestedPreview.unresolved.isEmpty {
                    results.append((fileName: relativePath, preview: ingestedPreview))
                }
            } catch {
                // Skip files that fail to parse — log but don't fail the whole scan
                AppLogger.shared.error(
                    "Failed to preview \(relativePath): \(error.localizedDescription)",
                    source: "PlaylistIngest"
                )
            }
        }

        return results
    }
}
