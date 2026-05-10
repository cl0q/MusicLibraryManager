import Foundation

/// Rockbox device detection — scans /Volumes for `.rockbox` directories.
///
/// Mirrors the Rust `DeviceDetector`.
enum DeviceDetector {

    struct RockboxDevice {
        let mountPoint: String
        let deviceName: String
        let availableSpace: Int64  // bytes
    }

    /// Detect connected Rockbox devices by scanning /Volumes.
    static func detectRockboxDevices() -> [RockboxDevice] {
        let fm = FileManager.default
        let volumesURL = URL(fileURLWithPath: "/Volumes")

        guard let volumes = try? fm.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.volumeNameKey, .volumeAvailableCapacityKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        var devices: [RockboxDevice] = []

        for volume in volumes {
            let rockboxDir = volume.appendingPathComponent(".rockbox")
            if fm.fileExists(atPath: rockboxDir.path) {
                let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent

                let attrs = try? fm.attributesOfFileSystem(forPath: volume.path)
                let space = (attrs?[.systemFreeSize] as? Int64) ?? 0

                devices.append(RockboxDevice(
                    mountPoint: volume.path,
                    deviceName: name,
                    availableSpace: space
                ))
            }
        }

        return devices
    }
}
