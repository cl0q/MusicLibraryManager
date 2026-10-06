import AppKit
import Foundation

// MARK: - Reachability of a sync destination and of the library folder (W3-SYNC)

/// Whether a sync destination and the library folder can be used now. Injectable so a sync can
/// be tested with a destination that "disconnects" mid-run without touching a real device.
protocol SyncDestinationChecking: Sendable {
    /// The destination folder exists and — when it lives on `/Volumes/<name>` — that volume is
    /// mounted (not a leftover folder on the Mac's own disk).
    func isDestinationReachable(_ path: String) -> Bool
    /// The library folder's disk is connected (`MountObserver.isConnected`, DEC-014).
    func isLibraryReachable(_ libraryRoot: String) -> Bool
    /// The pause between two checks while a sync waits for its device.
    func waitBeforeRecheck() async throws
    /// Which volume the destination is on (its UUID, else its creation date), `nil` when unknown.
    /// A waiting run resumes only when the same volume returns.
    func volumeIdentity(_ path: String) -> String?
}

extension SyncDestinationChecking {
    func volumeIdentity(_ path: String) -> String? { nil }
}

/// The app's checks: the same volume logic as `MountObserver` / `LibraryRootReachability`.
struct LiveSyncDestinationChecking: SyncDestinationChecking {
    var recheckInterval: Duration = .seconds(1)

    func isDestinationReachable(_ path: String) -> Bool {
        SyncDestination.isReachable(path)
    }

    func isLibraryReachable(_ libraryRoot: String) -> Bool {
        MountObserver.isConnected(libraryRoot: libraryRoot)
    }

    func waitBeforeRecheck() async throws {
        try await Task.sleep(for: recheckInterval)
    }

    func volumeIdentity(_ path: String) -> String? {
        SyncDestination.volumeIdentity(of: path)
    }
}

/// A sync could not start.
enum SyncRunError: LocalizedError, PlainCauseError {
    case destinationNotConnected(String)

    var errorDescription: String? {
        switch self {
        case .destinationNotConnected(let name): "“\(name)” is not connected."
        }
    }

    var plainCause: String {
        switch self {
        case .destinationNotConnected(let name): "“\(name)” is not connected"
        }
    }
}

/// Facts about a profile's destination: its device name, whether it is there, and ejecting it.
enum SyncDestination {
    /// `/Volumes/IPOD CLASSIC/Music` → `IPOD CLASSIC`; a folder elsewhere → its own name.
    static func deviceName(for path: String) -> String {
        if let volume = MountObserver.extractVolumePath(from: path) {
            return URL(fileURLWithPath: volume).lastPathComponent
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    /// `/Volumes/<name>` of the destination, or `nil` for a folder on the Mac's own disk.
    static func volumePath(for path: String) -> String? {
        MountObserver.extractVolumePath(from: path)
    }

    /// `volumeUUIDString` of the destination's volume; without one the volume's creation date;
    /// `nil` when neither can be read (a path that is not there, a file system without either).
    static func volumeIdentity(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let target = volumePath(for: path) ?? path
        let values = try? URL(fileURLWithPath: target).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeCreationDateKey])
        if let uuid = values?.volumeUUIDString { return "uuid:" + uuid }
        if let created = values?.volumeCreationDate { return "created:\(created.timeIntervalSince1970)" }
        return nil
    }

    /// See `SyncDestinationChecking.isDestinationReachable`.
    static func isReachable(_ path: String,
                            isVolumeMounted: (String) -> Bool = MountObserver.isVolumeMounted,
                            folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard !path.isEmpty else { return false }
        if let volume = volumePath(for: path), !isVolumeMounted(volume) { return false }
        return folderExists(path)
    }

    /// The destination's state in the words of §15.8.
    enum Status: Equatable, Sendable {
        /// No destination chosen.
        case none
        case connected
        /// The device (`/Volumes/<name>`) is not mounted.
        case notConnected
        /// The device is mounted but the chosen folder is not on it (`Folder not found on ‹DEVICE›`).
        case folderNotFound
    }

    static func status(for path: String,
                       isVolumeMounted: (String) -> Bool = MountObserver.isVolumeMounted,
                       folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Status {
        guard !path.isEmpty else { return .none }
        if let volume = volumePath(for: path) {
            guard isVolumeMounted(volume) else { return .notConnected }
            return folderExists(path) ? .connected : .folderNotFound
        }
        return folderExists(path) ? .connected : .notConnected
    }

    /// Free and total bytes of the destination's volume (`nil` when not readable).
    static func capacity(of path: String) -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return (free, Int64(total))
    }

    /// A mounted volume that can be ejected (a removable or ejectable disk, never the boot disk).
    static func isEjectable(_ path: String) -> Bool {
        guard let volume = volumePath(for: path), MountObserver.isVolumeMounted(volume) else { return false }
        let values = try? URL(fileURLWithPath: volume, isDirectory: true)
            .resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey])
        return values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
            || values?.volumeIsInternal == false
    }

    /// Unmount and eject the destination's volume off the main thread (§10 Q13). Throws when the
    /// system refuses (the disk is in use).
    static func eject(volumePath: String) async throws {
        let url = URL(fileURLWithPath: volumePath, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }
}

// MARK: - Failure reasons in plain words (V-SYNC-DETAIL.N11)

/// The reasons `SyncService` stores, said in the user's words at display time (like
/// `DownloadFailureReasonText`): a cause the user can act on, never developer language.
enum SyncFailureReasonText {
    static func plain(_ stored: String) -> String {
        switch stored {
        case "Destination is full": "The device is full"
        case "Source file is missing", "Source file not found", "No organized path for keepOriginals":
            "File missing in the library"
        case "The destination is not writable": "The device can’t be written to"
        case "Transcode failed": "Couldn’t convert to AAC"
        case "Track metadata not found in database": "The track is no longer in the library"
        case "Could not sync this track", "Unknown transcode mode": "Couldn’t copy this track"
        default: stored
        }
    }
}
