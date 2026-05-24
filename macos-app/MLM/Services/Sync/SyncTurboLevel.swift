import Foundation

/// Performance levels for audio transcoding during synchronization.
enum SyncTurboLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case low = "60%"
    case medium = "80%"
    case full = "100%"

    var id: String { self.rawValue }

    /// Fraction of available CPU cores utilized.
    var coresFraction: Double {
        switch self {
        case .low: return 0.6
        case .medium: return 0.8
        case .full: return 1.0
        }
    }

    /// Calculate the target concurrent worker count based on active CPU cores.
    func workerCount() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, Int(round(Double(cores) * coresFraction)))
    }
}
