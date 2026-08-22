import Foundation

/// Presents the retry allowance consistently while preserving explicit retries
/// for failures that have reached the legacy queue's automatic retry cap.
enum DownloadRetryBudget {
    static let maximumAttempts = 3

    static func remainingText(for failure: TrackDownloadFailure?) -> String {
        let attempts = failure?.attempts ?? 1
        let remaining = max(0, maximumAttempts - attempts)
        if remaining == 1 {
            return "1 attempt left"
        }
        return "\(remaining) attempts left"
    }
}
