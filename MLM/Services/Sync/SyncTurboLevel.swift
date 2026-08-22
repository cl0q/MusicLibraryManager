import Foundation

/// Shared background-processing levels for analysis, transcoding, and sync.
enum SyncTurboLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    // Keep the existing persisted values so installed profiles retain their
    // preference while the UI uses the user-facing names below.
    case conservative = "60%"
    case standard = "80%"
    case fast = "100%"

    var id: String { self.rawValue }

    /// Fraction of available CPU cores utilized.
    var coresFraction: Double {
        switch self {
        case .conservative: return 0.6
        case .standard: return 0.8
        case .fast: return 1.0
        }
    }

    var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .standard: "Standard"
        case .fast: "Fast"
        }
    }

    var detail: String {
        switch self {
        case .conservative: "Keeps the Mac responsive"
        case .standard: ""
        case .fast: "Uses all cores, fans may spin up"
        }
    }

    /// Calculate the target concurrent worker count based on active CPU cores.
    func workerCount() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, Int(round(Double(cores) * coresFraction)))
    }
}
