import Foundation

/// The persisted details for a failed download.
///
/// Dates use ISO 8601 strings in JSON so the value remains stable when read
/// by another app or a future version with different JSON date strategies.
struct TrackDownloadFailure: Codable, Equatable, Hashable, Sendable {
    let reason: String
    let date: Date
    let attempts: Int

    init(reason: String, date: Date, attempts: Int) {
        self.reason = reason
        self.date = date
        self.attempts = max(attempts, 1)
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case date
        case attempts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)

        if let attempts = try? container.decode(Int.self, forKey: .attempts) {
            self.attempts = max(attempts, 1)
        } else if let attemptsText = try? container.decode(String.self, forKey: .attempts),
                  let attempts = Int(attemptsText) {
            self.attempts = max(attempts, 1)
        } else {
            self.attempts = 1
        }

        if let dateText = try? container.decode(String.self, forKey: .date),
           let date = Self.date(from: dateText) {
            self.date = date
        } else {
            // Accept earlier JSONEncoder defaults, which encoded Date as a number.
            self.date = try container.decode(Date.self, forKey: .date)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(Self.dateFormatter.string(from: date), forKey: .date)
        try container.encode(attempts, forKey: .attempts)
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "Download failure JSON was not UTF-8.")
            )
        }
        return json
    }

    static func decodeJSON(_ json: String) throws -> TrackDownloadFailure {
        try JSONDecoder().decode(TrackDownloadFailure.self, from: Data(json.utf8))
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from text: String) -> Date? {
        dateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// A track's user-visible availability, derived from persisted track fields.
enum TrackAvailability: Codable, Equatable, Hashable, Sendable {
    case local
    case downloading
    case notDownloaded
    case failed(reason: String, date: Date, attempts: Int)
    case fileMissing

    private enum CodingKeys: String, CodingKey {
        case state
        case failure
    }

    private enum State: String, Codable {
        case local
        case downloading
        case notDownloaded = "not_downloaded"
        case failed
        case fileMissing = "file_missing"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .local:
            self = .local
        case .downloading:
            self = .downloading
        case .notDownloaded:
            self = .notDownloaded
        case .fileMissing:
            self = .fileMissing
        case .failed:
            let failure = try container.decode(TrackDownloadFailure.self, forKey: .failure)
            self = .failed(
                reason: failure.reason,
                date: failure.date,
                attempts: failure.attempts
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(State.local, forKey: .state)
        case .downloading:
            try container.encode(State.downloading, forKey: .state)
        case .notDownloaded:
            try container.encode(State.notDownloaded, forKey: .state)
        case let .failed(reason, date, attempts):
            try container.encode(State.failed, forKey: .state)
            try container.encode(
                TrackDownloadFailure(reason: reason, date: date, attempts: attempts),
                forKey: .failure
            )
        case .fileMissing:
            try container.encode(State.fileMissing, forKey: .state)
        }
    }
}
