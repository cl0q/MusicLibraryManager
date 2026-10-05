import DiskArbitration
import Foundation

/// Monitors disk mount/unmount events using the DiskArbitration framework.
///
/// Detects when the library drive is ejected or reconnected and posts
/// `.libraryDriveDidUnmount` / `.libraryDriveDidMount` (main thread) so the window can pause
/// playback, show the drive banner and check the files again.
///
/// One observer per library folder: `DependencyContainer.applyLibraryRoot` replaces it when
/// the folder changes. `stop()` unregisters both callbacks and drains the callback queue, so
/// a stopped observer can be released at once and never posts again.
///
/// ## Usage
/// ```swift
/// let observer = MountObserver(libraryRoot: "/Volumes/MusicDisk/Library")
/// observer.start()
/// ```
final class MountObserver: @unchecked Sendable {

    // MARK: - State

    /// The library root path to monitor.
    private let libraryRoot: String

    /// The volume path that contains the library root (e.g., "/Volumes/MusicDisk").
    let libraryVolumePath: String?

    /// Guards `mounted` and `isActive` (DA callbacks run on `daQueue`, readers on main).
    private let lock = NSLock()
    private var mounted: Bool
    /// `false` after `stop()`: late callbacks post nothing.
    private var isActive = true

    /// Whether the library volume is currently mounted.
    var isLibraryMounted: Bool {
        lock.lock(); defer { lock.unlock() }
        return mounted
    }

    /// Whether the observer has not been stopped.
    var isMonitoring: Bool {
        lock.lock(); defer { lock.unlock() }
        return isActive && session != nil
    }

    /// DiskArbitration session.
    private var session: DASession?

    /// Dispatch queue for DA callbacks.
    private let daQueue = DispatchQueue(label: "com.mlm.mount-observer", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// The C callbacks — fixed function pointers, so `stop()` unregisters exactly these.
    private static let appeared: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<MountObserver>.fromOpaque(context).takeUnretainedValue().handleDiskAppeared(disk)
    }
    private static let disappeared: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<MountObserver>.fromOpaque(context).takeUnretainedValue().handleDiskDisappeared(disk)
    }

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
        self.mounted = Self.isConnected(libraryRoot: libraryRoot, isVolumeMounted: isVolumeMounted)
        daQueue.setSpecific(key: Self.queueKey, value: true)
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
        guard session == nil, isMonitoringAllowed else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            AppLogger.shared.error("Mount observer: no DiskArbitration session", source: "Mount")
            return
        }

        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, Self.appeared, context)
        DARegisterDiskDisappearedCallback(session, nil, Self.disappeared, context)
        DASessionSetDispatchQueue(session, daQueue)
    }

    private var isMonitoringAllowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isActive
    }

    /// Stop monitoring disk events for good: unregister both callbacks, detach the session
    /// and wait for a callback already running on the queue, so nothing reaches this object
    /// afterwards.
    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(Self.appeared, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(Self.disappeared, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        if DispatchQueue.getSpecific(key: Self.queueKey) != true {
            daQueue.sync {}  // drain an in-flight callback
        }
    }

    // MARK: - Callbacks

    /// Called when a disk appears (mounted).
    private func handleDiskAppeared(_ disk: DADisk) {
        guard let mountPoint = Self.mountPoint(of: disk), isLibraryVolume(mountPoint: mountPoint) else { return }
        lock.lock()
        let wasUnmounted = !mounted
        mounted = true
        let active = isActive
        lock.unlock()
        guard wasUnmounted, active else { return }
        post(.libraryDriveDidMount, mountPoint: mountPoint)
    }

    /// Called when a disk disappears (unmounted/ejected).
    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let mountPoint = Self.mountPoint(of: disk), isLibraryVolume(mountPoint: mountPoint) else { return }
        lock.lock()
        mounted = false
        let active = isActive
        lock.unlock()
        guard active else { return }
        post(.libraryDriveDidUnmount, mountPoint: mountPoint)
    }

    /// Posts on main — only while this observer is still the container's current one, so an
    /// event for a library folder that is no longer current is ignored.
    private func post(_ name: Notification.Name, mountPoint: String) {
        let root = libraryRoot
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMonitoring, DependencyContainer.shared.mountObserver === self else { return }
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: ["mountPoint": mountPoint, "libraryRoot": root]
            )
        }
    }

    private static func mountPoint(of disk: DADisk) -> String? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL else {
            return nil
        }
        return volumePath.path
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
        lock.lock()
        mounted = connected
        lock.unlock()
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
