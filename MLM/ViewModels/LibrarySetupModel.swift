import Foundation
import GRDB
import Observation

/// Steps 2 and 3 of the in-window setup (V-SETUP, DEC-034) for a library that was just
/// created: choose the library folder (button or drop, reachability in words), then
/// `Scan and Import` — the existing folder import, registered with Activity, so
/// `Continue in Background` leaves it running and the Activity item carries it.
///
/// Lives on `LibraryLaunchCoordinator.setup` while the window shows the setup; the import
/// keeps running after the window moves on.
@MainActor
@Observable
final class LibrarySetupModel {
    enum Stage: Equatable {
        case folder
        case importing
        case finished(Outcome)
    }

    enum Outcome: Equatable {
        case imported(tracks: Int, skipped: Int)
        case stopped(imported: Int, of: Int)
        case failed(String)
    }

    /// Whether the chosen folder can be reached now (V-SETUP.N05, S-WIZARD.E06).
    enum Reachability: Equatable {
        case connected(volume: String?, freeBytes: Int64?)
        case notConnected(volume: String)
        case missing
    }

    struct Services {
        var makeImporter: @MainActor () -> ImportViewModel?
        var activity: ActivityCenter?
        /// Writes (`true`) or clears (`false`) the library's `setup_dismissed` flag.
        var rememberSetUpLater: @MainActor (Bool) async -> Void = { _ in }

        static var live: Services {
            Services(
                makeImporter: {
                    let container = DependencyContainer.shared
                    guard let service = container.importService, let config = container.configRepository else { return nil }
                    return ImportViewModel(importService: service, configRepository: config, activity: .shared)
                },
                activity: .shared,
                rememberSetUpLater: { dismissed in
                    guard let config = DependencyContainer.shared.configRepository else { return }
                    if dismissed {
                        try? await config.set(key: LibrarySetupModel.dismissedKey, value: "1")
                    } else {
                        try? await config.delete(key: LibrarySetupModel.dismissedKey)
                    }
                }
            )
        }
    }

    /// `app_config` key set by `Set Up Later`, cleared when the setup saves a library folder.
    nonisolated static let dismissedKey = "setup_dismissed"

    /// After a library opens: the window continues with the setup when the library is empty,
    /// has no library folder and its setup wasn't left with `Set Up Later` (S8). A library
    /// created this session always meets this (new, empty, no flag).
    nonisolated static func needsSetup(_ database: any DatabaseReader) async -> Bool {
        let facts = try? await database.read { db -> (tracks: Int, root: String?, dismissed: String?) in
            let tracks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
            let root = try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_root'")
            let dismissed = try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [dismissedKey])
            return (tracks, root, dismissed)
        }
        guard let facts else { return false }
        return facts.tracks == 0 && (facts.root ?? "").isEmpty && facts.dismissed != "1"
    }

    /// `Set Up Later`: remembered for this library.
    func setUpLater() async {
        await services.rememberSetUpLater(true)
    }

    let libraryName: String
    private(set) var stage: Stage = .folder
    private(set) var folder: URL?
    private(set) var reachability: Reachability?
    /// One sentence under the folder when something went wrong (UC-SHEET-17).
    private(set) var problem: String?
    private(set) var importer: ImportViewModel?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var importTask: Task<Void, Never>?

    /// Scans that wait for their disk outlive the setup screen.
    private static var waiting: [LibrarySetupModel] = []
    @ObservationIgnored private var mountObserver: NSObjectProtocol?

    init(libraryName: String, services: Services = .live) {
        self.libraryName = libraryName
        self.services = services
    }

    // MARK: - Step 2: library folder

    /// `Choose Folder…` or a folder dropped on the drop zone. Files are refused in words.
    func choose(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !exists || isDirectory.boolValue else {
            problem = "“\(url.lastPathComponent)” isn’t a folder. Drop the folder that contains your music."
            return
        }
        problem = nil
        folder = url.standardizedFileURL
        reachability = Self.reachability(of: url)
    }

    static func reachability(of url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Reachability {
        let volumePath = MountObserver.extractVolumePath(from: url.standardizedFileURL.path)
        let volume = volumePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        if fileExists(url.path) {
            let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return .connected(volume: volume, freeBytes: free)
        }
        if let volumePath, let volume, !fileExists(volumePath) {
            return .notConnected(volume: volume)
        }
        return .missing
    }

    /// `Connected · on “Lexxar” · 1.2 TB free`.
    var reachabilityText: String? {
        switch reachability {
        case .connected(let volume, let free)?:
            var parts = ["Connected", volume.map { "on “\($0)”" } ?? "on this Mac"]
            if let free { parts.append("\(free.formatted(.byteCount(style: .file))) free") }
            return parts.joined(separator: " · ")
        case .notConnected(let volume)?:
            return "Not connected — on “\(volume)”"
        case .missing?:
            return "Not found"
        case nil:
            return nil
        }
    }

    // MARK: - Step 3: scan and import

    /// `Scan and Import`: saves the folder as the library folder, then runs the folder import
    /// as an Activity operation.
    func scanAndImport() async {
        guard let folder, case .connected = reachability else { return }
        guard let importer = importer ?? services.makeImporter() else {
            problem = "The library isn’t ready yet. Try again in a moment."
            return
        }
        self.importer = importer
        await importer.setLibraryRoot(folder.path)
        guard importer.errorMessage == nil else {
            problem = "The folder couldn’t be saved. Try again."
            return
        }
        // A folder is set: a `Set Up Later` from before no longer applies (S8).
        await services.rememberSetUpLater(false)
        stage = .importing
        importTask = Task { [weak self] in
            await importer.importLibrary()
            self?.importDidEnd(importer)
        }
    }

    /// `Stop`: keeps what is already imported.
    func stop() {
        importer?.cancelImport()
    }

    private func importDidEnd(_ importer: ImportViewModel) {
        importTask = nil
        if let result = importer.lastResult {
            stage = .finished(result.cancelled
                ? .stopped(imported: result.succeeded, of: result.totalScanned)
                : .imported(tracks: result.succeeded, skipped: result.failed))
        } else {
            stage = .finished(.failed(importer.errorMessage ?? "The import didn’t start."))
        }
    }

    /// `Scan When Connected`: saves the folder; the scan waits in Activity for the disk and
    /// starts by itself when it is connected (V-SETUP.N07, UC-JOB-10).
    func scanWhenConnected() async {
        guard let folder, case .notConnected(let volume) = reachability else { return }
        guard let importer = importer ?? services.makeImporter() else {
            problem = "The library isn’t ready yet. Try again in a moment."
            return
        }
        self.importer = importer
        await importer.setLibraryRoot(folder.path)
        await services.rememberSetUpLater(false)
        let job = services.activity?.begin(
            .folderScan, title: "Scan “\(folder.lastPathComponent)”", subject: .folder(folder), itemNoun: .file)
        job?.setWaiting(.drive(volumeName: volume))
        Self.waiting.append(self)
        mountObserver = NotificationCenter.default.addObserver(
            forName: .libraryDriveDidMount, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.mountObserver { NotificationCenter.default.removeObserver(observer) }
                self.mountObserver = nil
                job?.discard()
                Self.waiting.removeAll { $0 === self }
                Task { @MainActor in await self.importer?.importLibrary() }
            }
        }
    }
}
