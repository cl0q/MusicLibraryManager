import Foundation

/// Task group helper for parallel batch processing.
///
/// Runs multiple tasks concurrently and collects their results.
/// Used by maintenance operations for parallel track processing.
func withTaskGroup<T: Sendable>(
    priority: TaskPriority = .medium,
    _ body: (inout TaskGroup<T>) -> Void
) async -> [T] {
    var group = TaskGroup<T>()
    body(&group)
    return await group.waitForAll()
}

/// Task group for collecting concurrent task results.
struct TaskGroup<T: Sendable> {
    private var tasks: [Task<T, Never>] = []
    
    mutating func addTask(priority: TaskPriority = .medium, operation: @escaping @Sendable () async -> T) {
        tasks.append(Task.detached(priority: priority, operation: operation))
    }
    
    func waitForAll() async -> [T] {
        var results: [T] = []
        for task in tasks {
            results.append(await task.value)
        }
        return results
    }
}

