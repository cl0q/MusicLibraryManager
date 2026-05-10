import SwiftUI

/// ViewModel for duplicate review queue management.
@Observable
final class ReviewQueueViewModel {
    private(set) var pendingItems: [ReviewItem] = []
    private(set) var isLoading = false
    private(set) var isScanning = false
    private(set) var scanResult: DeepScanService.DeepScanResult?
    private(set) var errorMessage: String?

    /// Track details loaded for display.
    private(set) var trackDetails: [Int64: Track] = [:]

    private let analysisRepository: AnalysisRepository
    private let trackRepository: TrackRepository
    private let deepScanService: DeepScanService

    init(analysisRepository: AnalysisRepository, trackRepository: TrackRepository) {
        self.analysisRepository = analysisRepository
        self.trackRepository = trackRepository
        self.deepScanService = DeepScanService(
            trackRepository: trackRepository,
            analysisRepository: analysisRepository
        )
    }

    // MARK: - Load

    func loadPendingReviews() async {
        isLoading = true
        do {
            pendingItems = try await analysisRepository.fetchPendingReviews()
            // Load track details
            for item in pendingItems {
                if trackDetails[item.trackId] == nil {
                    trackDetails[item.trackId] = try await trackRepository.fetchTrack(id: item.trackId)
                }
                if let relatedId = item.relatedTrackId, trackDetails[relatedId] == nil {
                    trackDetails[relatedId] = try await trackRepository.fetchTrack(id: relatedId)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Actions

    func resolveItem(_ item: ReviewItem) async {
        guard let id = item.id else { return }
        do {
            try await analysisRepository.resolveReview(id: id)
            pendingItems.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissItem(_ item: ReviewItem) async {
        guard let id = item.id else { return }
        do {
            try await analysisRepository.dismissReview(id: id)
            pendingItems.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDeepScan() async {
        isScanning = true
        errorMessage = nil
        do {
            scanResult = try await deepScanService.deepScan { processed, total in
                // Progress tracking happens in AppLogger
            }
            await loadPendingReviews()
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }
}
