import Foundation

/// Adapters that convert live ViewModel state into the plain value structs
/// consumed by `ActivityFeed.makeSnapshot`. These are NOT unit tested — they
/// are thin mappers that read from observable VMs and produce input structs.

extension DownloadViewModel {
    /// Build a `DownloadSourceState` from this VM's current observable state.
    func sourceState(operationID: UUID?) -> DownloadSourceState {
        DownloadSourceState(
            isDownloading: isDownloading,
            completedCount: completedCount,
            failedCount: failedCount,
            totalCount: totalCount,
            progress: progress,
            currentTrack: currentTrack,
            skippedCount: 0,
            cancelledCount: 0,
            hasActionableRetryFailures: hasActionableRetryFailures,
            queueItems: queueItems.map { item in
                ActivityChildItem(
                    id: String(item.trackId),
                    title: "\(item.artist) – \(item.title)",
                    statusText: item.status.rawValue,
                    statusColorName: colorName(for: item.status),
                    errorText: item.error
                )
            },
            operationID: operationID
        )
    }

    private func colorName(for status: DownloadItem.DownloadStatus) -> String {
        switch status {
        case .queued: return "muted"
        case .downloading: return "accent"
        case .transcoding: return "accent"
        case .completed: return "success"
        case .failed: return "error"
        case .skipped: return "muted"
        case .cancelled: return "attention"
        }
    }
}

extension SyncViewModel {
    func sourceState(operationID: UUID?) -> SyncSourceState {
        SyncSourceState(
            isSyncing: isSyncing,
            isPaused: isSyncPaused,
            processed: syncProcessed,
            total: syncTotal,
            progress: syncProgress,
            currentFile: syncCurrentFile,
            syncedCount: lastResult?.syncedCount,
            failedCount: lastResult?.failedCount,
            operationID: operationID
        )
    }
}

extension PerformanceQueueService {
    func sourceState() -> QueueSourceState {
        QueueSourceState(
            activeJobDescription: activeJobDescription,
            pendingAnalyses: pendingAnalysesCount,
            pendingDownloads: pendingDownloadsCount
        )
    }
}
