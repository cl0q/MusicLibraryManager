import SwiftUI

/// A grouped review unit. Scan results normally create one queue row per
/// group, while this also keeps pair-only rows from older databases readable.
struct ReviewGroup: Identifiable {
    let key: String
    let items: [ReviewItem]

    var id: String { key }
    var primaryItem: ReviewItem { items[0] }
    var actionType: String { primaryItem.actionType }
    var details: ReviewDetails? { primaryItem.reviewDetails }

    var memberTrackIDs: [Int64] {
        var ids = Set<Int64>()
        for item in items {
            ids.insert(item.trackId)
            if let relatedID = item.relatedTrackId {
                ids.insert(relatedID)
            }
            ids.formUnion(item.reviewDetails?.tracks.map(\.id) ?? [])
        }
        return ids.sorted()
    }

    var isMetadataConflict: Bool {
        actionType == "metadata_conflict"
    }

    var canUndo: Bool {
        details?.resolutionSnapshot != nil
    }
}

/// View model for the Review queue. All resolutions go through
/// `AnalysisRepository` so the marker/metadata changes and queue history are
/// committed atomically.
@MainActor
@Observable
final class ReviewQueueViewModel {
    private(set) var pendingGroups: [ReviewGroup] = []
    private(set) var resolvedGroups: [ReviewGroup] = []
    private(set) var isLoading = false
    private(set) var isScanning = false
    private(set) var scanProgress: MaintenanceProgressTracker.ProgressState?
    private(set) var scanResult: DeepScanService.DeepScanResult?
    private(set) var scanWasCancelled = false
    private(set) var errorMessage: String?
    private(set) var resolvingGroupKeys = Set<String>()

    /// Fresh tracks are used for choices and local preview; stored snapshots
    /// still make historical items intelligible if a track later disappears.
    private(set) var trackDetails: [Int64: Track] = [:]

    private let analysisRepository: AnalysisRepository
    private let trackRepository: TrackRepository
    private let deepScanService: DeepScanService
    private var scanTask: Task<Void, Never>?

    init(analysisRepository: AnalysisRepository, trackRepository: TrackRepository) {
        self.analysisRepository = analysisRepository
        self.trackRepository = trackRepository
        deepScanService = DeepScanService(
            trackRepository: trackRepository,
            analysisRepository: analysisRepository
        )
    }

    // MARK: - Load

    func loadReviews() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let pending = analysisRepository.fetchPendingReviews()
            async let resolved = analysisRepository.fetchResolvedReviews()
            let (pendingItems, resolvedItems) = try await (pending, resolved)
            pendingGroups = Self.groups(from: pendingItems)
            resolvedGroups = Self.groups(from: resolvedItems)
            await loadTrackDetails(for: pendingGroups + resolvedGroups)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func group(containing trackID: Int64) -> ReviewGroup? {
        pendingGroups.first { $0.memberTrackIDs.contains(trackID) }
    }

    func track(for id: Int64) -> Track? {
        trackDetails[id]
    }

    // MARK: - Scan

    func startDeepScan() {
        guard !isScanning else { return }
        isScanning = true
        scanWasCancelled = false
        scanProgress = nil
        scanResult = nil
        errorMessage = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.deepScanService.deepScan(turboMode: false) { [weak self] state in
                    Task { @MainActor in
                        self?.scanProgress = state
                    }
                }
                guard !Task.isCancelled else {
                    self.scanWasCancelled = true
                    self.isScanning = false
                    self.scanTask = nil
                    return
                }
                self.scanResult = result
                await self.loadReviews()
                self.publishChanges()
            } catch is CancellationError {
                self.scanWasCancelled = true
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isScanning = false
            self.scanTask = nil
        }
    }

    func cancelDeepScan() {
        guard isScanning else { return }
        scanWasCancelled = true
        scanProgress?.isCancelled = true
        scanTask?.cancel()
    }

    // MARK: - Resolution

    func keepRecommended(_ group: ReviewGroup) async -> Bool {
        if group.details?.recommendation?.action == .keepBoth {
            return await keepAll(group)
        }
        let recommendedID = group.details?.recommendation?.trackId
            ?? group.memberTrackIDs.first
        guard let recommendedID else { return false }
        return await apply(
            group,
            action: .keepRecommended,
            keptTrackIDs: [recommendedID]
        )
    }

    func keepManually(_ group: ReviewGroup, trackID: Int64) async -> Bool {
        await apply(group, action: .keepManual, keptTrackIDs: [trackID])
    }

    /// Keeping all explicitly clears duplicate markers in the group. No media
    /// files are moved to Trash because the app has no reversible file restore.
    func keepAll(_ group: ReviewGroup) async -> Bool {
        await apply(group, action: .keepAll)
    }

    func mergeMetadata(_ group: ReviewGroup, merge: ReviewMetadataMerge) async -> Bool {
        await apply(group, action: .mergeMetadata, metadataMerge: merge)
    }

    /// Dismissal is remembered in Review history so the same group is not
    /// repeatedly suggested until the user restores it.
    func dismiss(_ group: ReviewGroup) async -> Bool {
        await apply(group, action: .dismiss)
    }

    func undo(_ group: ReviewGroup) async -> Bool {
        resolvingGroupKeys.insert(group.key)
        defer { resolvingGroupKeys.remove(group.key) }
        do {
            try await analysisRepository.undoReviewResolution(groupKey: group.key)
            await loadReviews()
            publishChanges()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func apply(
        _ group: ReviewGroup,
        action: ReviewResolutionAction,
        keptTrackIDs: [Int64] = [],
        metadataMerge: ReviewMetadataMerge? = nil
    ) async -> Bool {
        resolvingGroupKeys.insert(group.key)
        defer { resolvingGroupKeys.remove(group.key) }
        do {
            try await analysisRepository.applyReviewResolution(
                groupKey: group.key,
                action: action,
                keptTrackIds: keptTrackIDs,
                metadataMerge: metadataMerge
            )
            await loadReviews()
            publishChanges()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadTrackDetails(for groups: [ReviewGroup]) async {
        let trackIDs = Set(groups.flatMap(\.memberTrackIDs))
        var loaded: [Int64: Track] = [:]
        for trackID in trackIDs {
            if let track = try? await trackRepository.fetchTrack(id: trackID) {
                loaded[trackID] = track
            }
        }
        trackDetails = loaded
    }

    private func publishChanges() {
        NotificationCenter.default.post(name: .reviewQueueDidChange, object: nil)
        // Existing library views use this data-change notification to reload
        // metadata and duplicate markers after a database-side edit.
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    private static func groups(from items: [ReviewItem]) -> [ReviewGroup] {
        var grouped: [String: [ReviewItem]] = [:]
        var order: [String] = []
        for item in items {
            let key = item.groupKey ?? "legacy:\(item.id ?? -1)"
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key in
            grouped[key].map { ReviewGroup(key: key, items: $0) }
        }
    }
}
