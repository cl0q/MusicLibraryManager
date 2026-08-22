import Foundation
import Combine

/// Debouncer utility for search input.
///
/// Delays execution until the user stops typing for a specified interval.
@Observable
final class Debouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    /// Debounce an async action.
    func debounce(_ action: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    /// Cancel any pending debounced action.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
