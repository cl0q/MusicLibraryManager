import Foundation
import Testing
@testable import MLM

/// The drive state is window-level and follows the library folder, also when it is set or
/// changed after launch (PP-SHELL-10/11). A folder on the Mac's own disk is always connected.
@Suite("LibraryDriveStateTests")
@MainActor
struct LibraryDriveStateTests {
    @Test func bootVolumeFoldersAreAlwaysConnected() {
        // Even a folder that doesn't exist: missing on a connected disk is "Not found", not offline.
        let observer = MountObserver(libraryRoot: "/Users/nobody/Music-\(UUID().uuidString)") { _ in false }
        #expect(observer.libraryVolumePath == nil)
        #expect(observer.isLibraryMounted)
        #expect(observer.checkMountStatus())
    }

    @Test func externalFoldersFollowTheVolume() {
        let unmounted = MountObserver(libraryRoot: "/Volumes/Lexxar/Music") { _ in false }
        #expect(unmounted.libraryVolumePath == "/Volumes/Lexxar")
        #expect(!unmounted.isLibraryMounted)
        let mounted = MountObserver(libraryRoot: "/Volumes/Lexxar/Music") { $0 == "/Volumes/Lexxar" }
        #expect(mounted.isLibraryMounted)
        #expect(MountObserver.isConnected(libraryRoot: "/Volumes/Lexxar/Music") { _ in true })
        #expect(MountObserver.isConnected(libraryRoot: "/Users/o/Music") { _ in false })
    }

    @Test func driveStateRetargetsWhenTheFolderChangesAfterLaunch() throws {
        let container = DependencyContainer(snapshotDatabase: try DatabaseManager.inMemory())
        #expect(container.mountObserver == nil)

        // Set after launch: a folder on this Mac.
        let local = FileManager.default.temporaryDirectory.path
        container.applyLibraryRoot(local, startMonitoring: false)
        #expect(container.hasLibraryRoot)
        #expect(container.mountObserver?.watchedLibraryRoot == local)
        #expect(container.isLibraryDriveMounted)
        #expect(LibraryDriveState.current(container) == LibraryDriveState(volumeName: nil, isConnected: true))
        #expect(!LibraryDriveState.current(container).isOffline)

        // Changed to a disk that isn't connected: the window says so.
        let disk = "/Volumes/NoSuchDisk-\(UUID().uuidString)"
        container.applyLibraryRoot(disk + "/Music", startMonitoring: false)
        #expect(container.mountObserver?.watchedLibraryRoot == disk + "/Music")
        #expect(!container.isLibraryDriveMounted)
        let offline = LibraryDriveState.current(container)
        #expect(offline.isOffline)
        #expect(offline.volumeName == URL(fileURLWithPath: disk).lastPathComponent)

        // Back to this Mac: connected again, without any disk event.
        container.applyLibraryRoot(local, startMonitoring: false)
        #expect(container.isLibraryDriveMounted)
        #expect(!LibraryDriveState.current(container).isOffline)

        // Cleared.
        container.applyLibraryRoot(nil, startMonitoring: false)
        #expect(!container.hasLibraryRoot)
        #expect(container.mountObserver == nil)
        #expect(container.isLibraryDriveMounted)
    }
}
