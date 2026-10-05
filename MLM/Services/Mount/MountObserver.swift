import DiskArbitration
import Foundation

/// Monitors disk mount/unmount events using the DiskArbitration framework.
///
/// Phase 18 — Detects when the library drive is ejected or reconnected,
/// and posts notifications so the app can:
/// - Pause playback on unmount
/// - Show a disconnected indicator in the sidebar
/// - Resume gracefully on remount
///
/// ## Usage
/// ```swift
/// let observer = MountObserver(libraryRoot: "/Volumes/MusicDisk/Library")
/// observer.start()
///
/// // Listen for mount/unmount
/// NotificationCenter.default.addObserver(
///     forName: .libraryDriveDidUnmount, ...
/// )
/// ```
final class MountObserver: @unchecked Sendable {

    // MARK: - State

    /// The library root path to monitor.
    private let libraryRoot: String

    /// The volume path that contains the library root (e.g., "/Volumes/MusicDisk").
    private(set) var libraryVolumePath: String?

    /// Whether the library volume is currently mounted.
    private(set) var isLibraryMounted: Bool = true

    /// DiskArbitration session.
    private var session: DASession?

    /// Dispatch queue for DA callbacks.
    private let daQueue = DispatchQueue(label: "com.mlm.mount-observer", qos: .utility)

    // MARK: - Init

    /// Initialize with the library root path.
    ///
    /// A library folder on the Mac's own disk is always connected (§15.2); one under
    /// `/Volumes/<name>` is connected while that volume is mounted. (A missing folder on a
    /// connected disk is "Not found" in Settings ▸ Library, not "not connected".)
    ///
    /// - Parameters:
    ///   - libraryRoot: The full path to the library root directory.
    ///   - isVolumeMounted: injectable for tests.
    init(libraryRoot: String, isVolumeMounted: (String) -> Bool = MountObserver.isVolumeMounted) {
        self.libraryRoot = libraryRoot
        self.libraryVolumePath = Self.extractVolumePath(from: libraryRoot)
        self.isLibraryMounted = Self.isConnected(libraryRoot: libraryRoot, isVolumeMounted: isVolumeMounted)
    }

    /// The library root this observer watches.
    var watchedLibraryRoot: String { libraryRoot }

    /// Connected = on the boot disk, or its `/Volumes/<name>` volume is mounted.
    static func isConnected(libraryRoot: String, isVolumeMounted: (String) -> Bool = MountObserver.isVolumeMounted) -> Bool {
        guard let volume = extractVolumePath(from: libraryRoot) else { return true }
        return isVolumeMounted(volume)
    }

    /// `true` when `volumePath` (`/Volumes/<name>`) is a mounted volume — not merely a
    /// leftover empty directory on the boot disk (whose volume is `/`).
    static func isVolumeMounted(_ volumePath: String) -> Bool {
        let url = URL(fileURLWithPath: volumePath, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume else { return false }
        return volume.standardizedFileURL.path == url.standardizedFileURL.path
    }

    deinit {
        stop()
    }

    // MARK: - Start/Stop

    /// Start monitoring disk events.
    func start() {
        guard session == nil else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("[MountObserver] Failed to create DiskArbitration session")
            return
        }

        self.session = session
        DASessionSetDispatchQueue(session, daQueue)

        // Register for disk appeared (mount) events
        DARegisterDiskAppearedCallback(
            session,
            nil, // Match all disks
            { disk, context in
                guard let context else { return }
                let observer = Unmanaged<MountObserver>.fromOpaque(context).takeUnretainedValue()
                observer.handleDiskAppeared(disk)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Register for disk disappeared (unmount) events
        DARegisterDiskDisappearedCallback(
            session,
            nil, // Match all disks
            { disk, context in
                guard let context else { return }
                let observer = Unmanaged<MountObserver>.fromOpaque(context).takeUnretainedValue()
                observer.handleDiskDisappeared(disk)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        print("[MountObserver] Started monitoring for library at: \(libraryRoot)")
    }

    /// Stop monitoring disk events.
    func stop() {
        if let session {
            DASessionSetDispatchQueue(session, nil)
            DAUnregisterCallback(session, Unmanaged.passUnretained(self).toOpaque(), nil)
            self.session = nil
        }
    }

    // MARK: - Callbacks

    /// Called when a disk appears (mounted).
    private func handleDiskAppeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL else {
            return
        }

        let mountPoint = volumePath.path

        // Check if the reappeared volume contains our library
        if isLibraryVolume(mountPoint: mountPoint) {
            let wasUnmounted = !isLibraryMounted
            isLibraryMounted = true

            if wasUnmounted {
                print("[MountObserver] Library volume remounted at: \(mountPoint)")

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .libraryDriveDidMount,
                        object: nil,
                        userInfo: [
                            "mountPoint": mountPoint,
                            "libraryRoot": self.libraryRoot,
                        ]
                    )
                }
            }
        }
    }

    /// Called when a disk disappears (unmounted/ejected).
    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL else {
            return
        }

        let mountPoint = volumePath.path

        // Check if the disappeared volume was our library volume
        if isLibraryVolume(mountPoint: mountPoint) {
            isLibraryMounted = false

            print("[MountObserver] Library volume unmounted: \(mountPoint)")

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .libraryDriveDidUnmount,
                    object: nil,
                    userInfo: [
                        "mountPoint": mountPoint,
                        "libraryRoot": self.libraryRoot,
                    ]
                )
            }
        }
    }

    // MARK: - Volume Detection

    /// Check if a mount point is the volume containing our library.
    private func isLibraryVolume(mountPoint: String) -> Bool {
        guard let volumePath = libraryVolumePath else {
            // Library is on the boot volume — never "unmounted"
            return false
        }
        return mountPoint == volumePath
    }

    /// Extract the volume mount point from a full path.
    ///
    /// Examples:
    /// - `/Volumes/MusicDisk/Library/00_Artists` → `/Volumes/MusicDisk`
    /// - `/Users/foo/Music` → `nil` (boot volume, no monitoring needed)
    static func extractVolumePath(from path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else {
            return nil  // On boot volume — doesn't unmount
        }

        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }

        // /Volumes/<VolumeName>
        return "/\(components[0])/\(components[1])"
    }

    /// Manually check if the library volume is currently connected (`Try Again` on the banner).
    func checkMountStatus() -> Bool {
        let connected = Self.isConnected(libraryRoot: libraryRoot)
        isLibraryMounted = connected
        return connected
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the library's external drive is unmounted/ejected.
    ///
    /// - `userInfo["mountPoint"]`: `String` — the volume mount point
    /// - `userInfo["libraryRoot"]`: `String` — the library root path
    static let libraryDriveDidUnmount = Notification.Name("MLMLibraryDriveDidUnmount")

    /// Posted when the library's external drive is remounted.
    ///
    /// - `userInfo["mountPoint"]`: `String` — the volume mount point
    /// - `userInfo["libraryRoot"]`: `String` — the library root path
    static let libraryDriveDidMount = Notification.Name("MLMLibraryDriveDidMount")
}
