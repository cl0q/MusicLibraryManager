import Foundation
import Observation
import Synchronization

/// A library file that can't be a library (V-LAUNCH-INVALID, A-LIBFILE-INVALID).
struct InvalidLibraryFile: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// No `music_library.db` inside, or not a folder at all.
        case noDatabase
        /// Its manifest was written by a newer MLM.
        case newerVersion
        /// The database inside can't be read (damaged, or without the identity it should have).
        case unreadable
    }

    let url: URL
    let cause: Cause
    /// Raw text behind `Details`.
    let details: String

    var fileName: String { url.lastPathComponent }

    /// `“Festival Set 2024.mlibm” isn’t a valid library file` (UC-STATE §15.1).
    var title: String { "“\(fileName)” isn’t a valid library file" }

    /// The cause in plain words, ending with what is safe.
    var message: String {
        switch cause {
        case .noDatabase:
            return "It doesn’t contain a library database. The file may be incomplete or damaged. MLM didn’t change it."
        case .newerVersion:
            return "It was made by a newer version of MLM. Update MLM to open it. MLM didn’t change the file."
        case .unreadable:
            return "Its library database can’t be read. The file may be damaged. MLM didn’t change it."
        }
    }
}

/// A library that couldn't be opened after it was chosen (V-LAUNCH-FAILED, PP-SHELL-12): the
/// sentence names the library and what is safe; the raw error is behind `Details`.
struct LaunchFailure: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// The database couldn't be read; nothing was written yet.
        case unreadable
        /// The pre-update backup failed, so the update didn't start.
        case backupBeforeUpdate
        /// An update of the library database failed (a backup was made before it started).
        case update
        /// `libraries.json` can't be read or saved; `newerVersion` = written by a newer MLM.
        case libraryList(newerVersion: Bool)
        /// An interrupted library file setup couldn't be finished.
        case setupInterrupted
        /// The database opened and is up to date, but starting the library failed afterwards
        /// (e.g. reading its settings). Nothing is claimed about the file (S7).
        case startup
    }

    let name: String
    /// What was being opened; `nil` when the failure isn't about one library.
    let location: LibraryLocation?
    let cause: Cause
    let details: String

    var title: String {
        if case .libraryList = cause { return "MLM couldn’t read its list of libraries" }
        return "“\(name)” couldn’t be opened"
    }

    var message: String {
        switch cause {
        case .unreadable:
            return "The library database couldn’t be read. Your music files are not affected, and MLM didn’t change the library file."
        case .backupBeforeUpdate:
            return "MLM couldn’t make the backup it needs before updating the library, so nothing was updated. Your music files are not affected."
        case .update:
            return "The library couldn’t be updated to this version of MLM. A backup was made before the update started. Your music files are not affected."
        case .libraryList(newerVersion: true):
            return "The list was saved by a newer version of MLM. Update MLM to open your libraries. MLM didn’t change the list."
        case .libraryList(newerVersion: false):
            return "The file that lists your libraries couldn’t be read or saved. Your libraries and music files are not affected."
        case .setupInterrupted:
            return "MLM couldn’t finish the library file setup that was interrupted last time. Your previous library is not changed."
        case .startup:
            return "MLM couldn’t open the library. Your music files are not affected. The details below say what went wrong."
        }
    }

    /// `Try Again` is the default only where trying again is harmless; after a failed update
    /// it would start the update again, so `Choose Another Library` is the default (S2).
    var tryAgainIsDefault: Bool {
        cause != .update
    }

    /// `Choose Another Library` leads somewhere only when the list of libraries works.
    var offersChooseAnother: Bool {
        if case .libraryList = cause { return false }
        return true
    }

    /// `Restore from Backup…` is about one library's database.
    var mayOfferRestore: Bool {
        switch cause {
        case .unreadable, .backupBeforeUpdate, .update: return location != nil
        case .libraryList, .setupInterrupted, .startup: return false
        }
    }

    /// The step the error came from decides what is safe to say (S7): only errors that
    /// `DatabaseManager` marked with their step say more than "couldn’t open".
    static func cause(for error: Error) -> Cause {
        guard let openError = error as? LibraryOpenError else { return .startup }
        switch openError.stage {
        case .opening: return .unreadable
        case .backingUp: return .backupBeforeUpdate
        case .updating: return .update
        }
    }
}

/// Inline errors of `New Library` and the setup's first step (UC-SHEET-05/18).
enum NewLibraryError: Equatable, Sendable {
    case emptyName
    case nameTaken(String)
    case notWritable(folder: String)
    case failed(name: String, cause: String)
    /// A restore or a library file setup is running (S1).
    case busy(String)

    var message: String {
        switch self {
        case .busy(let reason): return reason
        case .emptyName: return "Enter a name for the library."
        case .nameTaken(let name): return "A library named “\(name)” already exists there. Choose another name."
        case .notWritable(let folder): return "MLM can’t write to “\(folder)”. Choose another location."
        case .failed(let name, let cause): return "The library “\(name)” couldn’t be created — \(cause)"
        }
    }
}

/// Chooses and opens the library at launch, before the dependency container exists, and
/// switches libraries by relaunching (A3 Step-0 decision 1).
///
/// Flow: resolver decision → validate the library file (`Checking the library file…`) →
/// update the registry → hand the location to `openLibrary` (the container), which reports
/// its phases (`Backing up before update…`, `Updating the library… 3 of 5`). Anything that
/// needs the user ends in a `screen` the window shows instead of the library: the picker
/// (V-PICKER) with per-row states, the in-window setup (V-SETUP), the loading, failed and
/// invalid states (W3-LAUNCH, DEC-031/032/034).
///
/// What adoption, validation, the registry, backups and the relaunch do to files is the A3
/// logic, unchanged; this type adds states, phases and actions around it.
@MainActor
@Observable
final class LibraryLaunchCoordinator {

    /// What the window shows while no library is open (and `.opened` once one is).
    enum Screen: Equatable {
        case resolving
        case opened
        /// V-PICKER: every library MLM knows, with its state in words.
        case picker
        /// V-SETUP step 1: nothing registered and no old install — create the first library.
        case firstRunSetup
        /// V-LAUNCH-LOADING: `Opening “‹name›”…` + phase.
        case loading(Loading)
        /// V-LAUNCH-FAILED.
        case failed(LaunchFailure)
        /// V-LAUNCH-INVALID.
        case invalid(InvalidLibraryFile)
    }

    struct Loading: Equatable {
        let name: String
        var phase: LibraryOpenPhase
    }

    /// A library chosen to open that can't be. At launch unavailable and mismatched ones are
    /// picker rows; with a library open each is an alert (A-LIBFILE-*, A-LIB-COPY).
    enum Problem: Equatable {
        case unavailable(name: String, url: URL, availability: LibraryAvailability)
        case mismatch(name: String, url: URL, details: String)
        case invalid(InvalidLibraryFile)
        /// `“‹copy›” is a copy of “‹original›”` — a Finder copy; `Open as Separate Library`.
        case duplicateCopy(name: String, originalName: String, url: URL)
        /// A-LIBFILE-INVALID.N01: a new library failed after its sheet closed.
        case creationFailed(name: String, message: String)
        /// The list of libraries couldn't be updated; nothing changed.
        case listNotSaved(name: String)
        /// A switch refused while work that must not be cut off runs (S4); `OK` only.
        case refused(String)
    }

    /// `Switch to “‹name›”?` — waiting for `Switch and Relaunch` / `Cancel`.
    struct SwitchRequest: Equatable {
        enum Target: Equatable {
            case open(URL)
            /// A new library (S-NEWLIB with a library open): created only once confirmed, so a
            /// cancelled switch leaves nothing behind.
            case create(directory: URL)
        }

        let name: String
        let target: Target

        var url: URL? {
            if case .open(let url) = target { return url }
            return nil
        }

        static func open(_ url: URL, name: String) -> SwitchRequest {
            SwitchRequest(name: name, target: .open(url))
        }
    }

    /// The `New Library` sheet is up, with this name prefilled.
    struct NewLibraryRequest: Identifiable, Equatable {
        let id = UUID()
        let defaultName: String
    }

    /// A registered library for `Open Recent`, with whether it can be opened now.
    struct RecentLibrary: Equatable, Identifiable {
        let entry: LibraryRegistry.Entry
        let availability: LibraryAvailability
        var id: String { entry.libraryId }
    }

    /// The system open panel for a library file (`Open Other…`, `Open Library…`, `Locate…`).
    struct LibraryFileRequest: Identifiable, Equatable {
        enum Purpose: Equatable {
            case open
            case locate(rowID: String)
        }

        let id = UUID()
        let purpose: Purpose
    }

    /// The library a launch problem is about: heads the picker (`“‹name›” can’t be opened`).
    struct PickerFocus: Equatable {
        let name: String
        let url: URL
    }

    /// Progress of the adoption sheet.
    enum AdoptionState: Equatable {
        case idle
        case running(LibraryAdoption.Phase)
        case succeeded(LibraryAdoption.Result)
        /// Nothing changed; `details` goes behind the `Details` disclosure.
        case failed(details: String)
    }

    enum SwitchOutcome: Equatable {
        case relaunching
        case failed(Problem)
    }

    /// One-shot "open this library file at the next launch", so a switch survives the
    /// relaunch even when "Open the last library at launch" is off.
    struct PendingOpenStore {
        var take: () -> String?
        var set: (String?) -> Void

        static let userDefaultsKey = "MLMPendingLibraryPath"

        static var userDefaults: PendingOpenStore {
            PendingOpenStore(
                take: {
                    let path = UserDefaults.standard.string(forKey: userDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: userDefaultsKey)
                    return path
                },
                set: { UserDefaults.standard.set($0, forKey: userDefaultsKey) }
            )
        }
    }

    private(set) var screen: Screen = .resolving
    private(set) var adoptionState: AdoptionState = .idle
    /// `Set up your library file` is up over the picker (S-ADOPT).
    private(set) var adoptionOffer = false
    private(set) var pendingSwitch: SwitchRequest?
    private(set) var newLibraryRequest: NewLibraryRequest?
    /// A problem shown as an alert: with a library open any problem, at launch a Finder copy.
    private(set) var switchProblem: Problem?
    private(set) var libraryFileRequest: LibraryFileRequest?
    /// Registry setting behind `Open the last library at launch`.
    private(set) var rememberLastLibrary = true
    /// Other registered libraries, most recently opened first (`Open Recent`).
    private(set) var recentLibraries: [RecentLibrary] = []
    /// The open library file, `nil` for the legacy layout or before anything is open.
    private(set) var activePackageURL: URL?
    private(set) var activeLibraryName: String?
    private var activeLibraryId: String?

    // MARK: Picker state

    private(set) var pickerRows: [LibraryPickerRow] = []
    private(set) var pickerFocus: PickerFocus?
    /// A line under a row after `Try Again` / `Locate…` (`Checked just now — …`).
    private(set) var rowNotes: [String: String] = [:]
    /// The last `Remove from List`, undoable for this session.
    private(set) var lastRemoval: LibraryRegistry.Removal?
    /// Library files found not to match their database this session (path → details).
    private var mismatches: [String: String] = [:]
    private var unlisted: [UnlistedLibraryProblem] = []

    /// Steps 2–3 of the setup for a library that was just created (V-SETUP); the window shows
    /// them instead of the library until the user leaves them.
    private(set) var setup: LibrarySetupModel?
    /// `Restore from Backup…` of the failed library (S-LAUNCH-RESTORE), when possible.
    private(set) var restore: LaunchRestoreModel?
    /// Phases the current open went through, in order (the loading screen shows the last).
    private(set) var openPhases: [LibraryOpenPhase] = []

    /// A restore from the failed state is replacing the library's database (S1).
    private(set) var isRestoreRunning = false
    /// The name given to the running adoption (for the quit refusal).
    private var adoptingName: String?
    /// Details of the last failed library file setup (the interrupted row's `Details`).
    private var lastAdoptionError: String?

    /// A restore or a library file setup is changing library files: nothing else may open,
    /// create or switch a library until it ends (S1). Library files opened meanwhile wait.
    var isBusy: Bool { isRestoreRunning || adoptionState.isRunning }

    /// Why library commands are disabled while `isBusy` (UC-COPY-13).
    var busyReason: String? {
        if isRestoreRunning {
            return "“\(restore?.libraryName ?? workSubjectName ?? "The library")” is being restored. Wait until it finishes."
        }
        if adoptionState.isRunning { return "The library file is being set up. Wait until it finishes." }
        return nil
    }

    /// The open library's name — `nil` while none is open (then nothing is promised to
    /// continue in it).
    var openLibraryName: String? {
        guard screen == .opened else { return nil }
        return activeLibraryName
            ?? activePackageURL?.deletingPathExtension().lastPathComponent
            ?? LibraryPickerRows.legacyName
    }

    /// The library that running work is about: the one being restored or set up, else the
    /// open one (`Quit MLM?`, the quit refusal).
    var workSubjectName: String? {
        if isRestoreRunning, let name = restore?.libraryName { return name }
        if adoptionState.isRunning, let adoptingName { return adoptingName }
        return openLibraryName
    }

    private var hasStarted = false
    /// A library file opened before launch started (double-click to launch).
    private var launchOpenURL: URL?
    /// A library file opened while launch was resolving, loading or asking to adopt; handled
    /// once that settles (D-LIBFILE-OPEN: queued, never dropped).
    private var queuedOpenURL: URL?
    private var openGeneration = 0

    let store: LibraryRegistryStore
    private let adoption: LibraryAdoption
    private var legacyDatabaseURL: URL { adoption.environment.legacyDatabaseURL }
    private let now: () -> Date
    private let pendingOpen: PendingOpenStore
    private let openLibrary: (LibraryLocation, @escaping LibraryOpenProgress) async throws -> Void
    private let reportFailure: (Error) -> Void
    private let relaunch: () -> Void
    private let needsSetup: () async -> Bool
    private let setupServices: LibrarySetupModel.Services
    private let activeOperations: () -> [ActivityOperation]

    /// - Parameters:
    ///   - openLibrary: opens the location into the container, reporting its phases.
    ///   - needsSetup: after an open — the library is empty, has no library folder and its
    ///     setup wasn't left with `Set Up Later`, so the window continues with setup step 2.
    ///   - activeOperations: Activity's running work (a switch is refused while a restore,
    ///     a library file setup or a path migration runs — S4).
    init(
        store: LibraryRegistryStore = LibraryRegistryStore(),
        adoption: LibraryAdoption,
        now: @escaping () -> Date = { Date() },
        pendingOpen: PendingOpenStore = .userDefaults,
        openLibrary: @escaping (LibraryLocation, @escaping LibraryOpenProgress) async throws -> Void,
        reportFailure: @escaping (Error) -> Void,
        relaunch: @escaping () -> Void,
        needsSetup: @escaping () async -> Bool = { false },
        setupServices: LibrarySetupModel.Services = .live,
        activeOperations: @escaping () -> [ActivityOperation] = { [] }
    ) {
        self.activeOperations = activeOperations
        self.store = store
        self.adoption = adoption
        self.now = now
        self.pendingOpen = pendingOpen
        self.openLibrary = openLibrary
        self.reportFailure = reportFailure
        self.relaunch = relaunch
        self.needsSetup = needsSetup
        self.setupServices = setupServices
    }

    /// The app's coordinator: opens libraries into `DependencyContainer.shared`.
    static let shared = LibraryLaunchCoordinator(
        adoption: LibraryAdoption(),
        openLibrary: { location, progress in
            try await DependencyContainer.shared.initialize(location: location, progress: progress)
        },
        reportFailure: { error in
            AppLogger.shared.error("Opening the library failed: \(error)", source: "Library")
        },
        relaunch: { BackupService.relaunchApp() },
        needsSetup: {
            let container = DependencyContainer.shared
            guard !container.hasLibraryRoot, let pool = container.databaseManager?.pool else { return false }
            return await LibrarySetupModel.needsSetup(pool)
        },
        activeOperations: { ActivityCenter.shared.activeOperations }
    )

    /// Refuses a switch while work that must not be cut off runs (S4); `nil` = allowed.
    var switchRefusal: String? {
        RunningWorkSummary(operations: activeOperations()).refusal(libraryName: workSubjectName, switching: true)
    }

    // MARK: - Launch

    /// Resolve and open the library for this launch.
    ///
    /// - Parameter openedFileURL: a library file the user opened to launch the app.
    func start(openedFileURL: URL? = nil) async {
        await resolveAndOpen(openedFileURL: openedFileURL)
        await drainQueuedOpen()
    }

    private func resolveAndOpen(openedFileURL: URL?) async {
        hasStarted = true
        screen = .resolving
        let registry: LibraryRegistry
        do {
            registry = try store.load(now: now()).registry
        } catch {
            reportFailure(error)
            screen = .failed(LaunchFailure(
                name: "MLM", location: nil,
                cause: .libraryList(newerVersion: error is LibraryRegistryStore.LoadError),
                details: "\(error)\n\(store.fileURL.path)"))
            return
        }
        refreshRegistryState(registry)

        let pending = pendingOpen.take().map { URL(fileURLWithPath: $0) }
        let decision = LibraryLaunchResolver.resolve(.init(
            registry: registry,
            legacyDatabaseExists: FileManager.default.fileExists(atPath: legacyDatabaseURL.path),
            adoptionInProgress: adoption.isInProgress,
            openedFileURL: openedFileURL ?? launchOpenURL.take() ?? pending,
            availability: { LibraryRegistry.availability(of: $0) }
        ))

        switch decision {
        case .openPackage(let url, _):
            await open(packageAt: url)
        case .offerAdoption:
            // Over the picker; `Not Now` stays there (A0 D7, ROADMAP A3 note 13).
            adoptionState = .idle
            adoptionOffer = true
            showPicker()
        case .resumeAdoption:
            await resumeAdoption()
        case .createFirstLibrary:
            screen = .firstRunSetup
        case .noLibrary:
            showPicker()
        case .libraryUnavailable(let entry, _):
            showPicker(focus: PickerFocus(name: entry.displayName, url: entry.url))
        }
    }

    /// A library file that arrived while the app was busy.
    private func drainQueuedOpen() async {
        guard !adoptionOffer, !isBusy, let queued = queuedOpenURL.take() else { return }
        await handleOpen(queued)
    }

    /// `OK` / `Cancel` on a problem alert.
    func dismissProblem() {
        switchProblem = nil
    }

    // MARK: - Opening files (double-click, Open Library…, Open Recent, drops)

    /// Route a library file the user opened, whatever state the app is in.
    func handleOpen(_ url: URL) async {
        let url = Self.canonical(url)
        guard hasStarted else {
            launchOpenURL = url
            return
        }
        if adoptionOffer || isBusy {
            // `Set up your library file`, or a restore / setup that is changing library files,
            // comes first; the file is opened afterwards (S1).
            queuedOpenURL = url
            return
        }
        switch screen {
        case .opened:
            guard url.resolvingSymlinksInPath().path != activePackageURL?.resolvingSymlinksInPath().path else { return }
            pendingSwitch = .open(url, name: displayName(forPackage: url))
        case .resolving, .loading:
            queuedOpenURL = url
        default:
            await open(packageAt: url)
        }
    }

    /// `Switch and Relaunch` on `Switch to “‹name›”?`.
    func confirmSwitch() {
        guard let request = pendingSwitch else { return }
        pendingSwitch = nil
        if let refusal = switchRefusal {
            switchProblem = .refused(refusal)
            return
        }
        switch request.target {
        case .open(let url):
            if case .failed(let problem) = switchLibrary(to: url) { switchProblem = problem }
        case .create(let directory):
            let package: URL
            do {
                package = try LibraryPackage.createEmpty(
                    named: request.name, libraryId: UUID().uuidString.lowercased(), in: directory, now: now())
            } catch {
                AppLogger.shared.error("Creating a library failed: \(error)", source: "Library")
                switchProblem = .creationFailed(
                    name: request.name, message: Self.creationFailureMessage(error, folder: directory))
                return
            }
            if case .failed = switchLibrary(to: package) {
                // The file was made a moment ago, is empty and isn't on the list: take it away
                // again so nothing half-made stays behind (N2).
                let canonical = Self.canonical(package)
                if (try? store.load(now: now()).registry.entry(at: canonical)) == nil {
                    try? FileManager.default.removeItem(at: canonical)
                }
                switchProblem = .creationFailed(
                    name: request.name,
                    message: "MLM couldn’t add it to its list of libraries, so the new library file was removed again. Nothing was added to your libraries.")
            }
        }
    }

    func cancelSwitch() {
        pendingSwitch = nil
    }

    /// `Open as Separate Library` on a Finder copy: new identity, then open (no library open)
    /// or the switch confirmation (a library open — A-LIB-COPY.E01).
    func openAsSeparateLibrary(_ url: URL) async {
        let url = Self.canonical(url)
        switchProblem = nil
        do {
            try LibraryPackage.reassignLibraryId(UUID().uuidString.lowercased(), in: url, now: now())
        } catch {
            let problem = InvalidLibraryFile(url: url, cause: .unreadable, details: "\(error)\n\(url.path)")
            if screen == .opened { switchProblem = .invalid(problem) } else { screen = .invalid(problem) }
            return
        }
        if screen == .opened {
            pendingSwitch = .open(url, name: displayName(forPackage: url))
        } else {
            await open(packageAt: url)
        }
    }

    // MARK: - Settings

    func setRememberLastLibrary(_ remember: Bool) {
        guard var registry = try? store.load(now: now()).registry else { return }
        registry.rememberLastLibrary = remember
        do {
            try store.save(registry)
            rememberLastLibrary = remember
        } catch {
            AppLogger.shared.error("Saving library setting failed: \(error)", source: "Library")
        }
    }

    private func refreshRegistryState(_ registry: LibraryRegistry) {
        rememberLastLibrary = registry.rememberLastLibrary
        recentLibraries = registry.recentEntries
            .filter { $0.libraryId != activeLibraryId }
            .map { RecentLibrary(entry: $0, availability: LibraryRegistry.availability(of: $0.url)) }
        if let activeLibraryId, let entry = registry.entry(withId: activeLibraryId) {
            activeLibraryName = entry.displayName
        }
        // An adoption journal left behind (interrupted, or a rollback that failed) is shown as
        // its own row instead of the old install, never as "No libraries yet" (S3).
        let interrupted = adoption.isInProgress
        let legacy = FileManager.default.fileExists(atPath: legacyDatabaseURL.path) && !interrupted
        pickerRows = LibraryPickerRows.build(
            registry: registry,
            legacyDatabase: legacy ? legacyDatabaseURL : nil,
            interruptedSetup: interrupted ? InterruptedSetup(
                name: adoption.pendingName() ?? LibraryPickerRows.legacyName,
                journal: adoption.journalURL,
                details: lastAdoptionError ?? "Setup journal: \(adoption.journalURL.path)") : nil,
            mismatches: mismatches,
            unlisted: unlisted
        )
    }

    /// `Try Again` on `‹name› (setup interrupted)`: finishes the setup past its point of no
    /// return, or undoes it and offers it again (the launch's own resume, S3).
    func retryInterruptedSetup() async {
        guard !isBusy, adoption.isInProgress else { return }
        await resumeAdoption()
    }

    // MARK: - Picker (V-PICKER)

    private func showPicker(focus: PickerFocus? = nil) {
        pickerFocus = focus
        screen = .picker
        refreshPicker()
    }

    /// Re-read the list and every row's state (mount events, `Try Again`).
    func refreshPicker() {
        guard let registry = try? store.load(now: now()).registry else { return }
        refreshRegistryState(registry)
    }

    /// `Open`, double-click or Return on a row.
    func openRow(_ row: LibraryPickerRow) async {
        guard row.canOpen, !isBusy else { return }
        lastRemoval = nil
        switch row.kind {
        case .legacy:
            await openLegacyLibrary()
        case .registered, .unlisted:
            await open(packageAt: row.url)
        case .interruptedSetup:
            break
        }
    }

    /// The old install opened as it is — what `Not Now` did before (no change to what opens).
    func openLegacyLibrary() async {
        guard !isBusy else { return }
        adoptionOffer = false
        adoptionState = .idle
        await finishOpening(.legacy(legacyDatabaseURL), name: LibraryPickerRows.legacyName)
    }

    /// `Try Again` on a Not connected (or Not found) row: opens it if it is there now.
    func tryAgain(_ row: LibraryPickerRow) async {
        if LibraryRegistry.availability(of: row.url) == .available {
            rowNotes[row.id] = nil
            await open(packageAt: row.url)
            return
        }
        if case .notConnected(let volume) = row.state {
            rowNotes[row.id] = "Checked just now — “\(volume)” is still not connected."
        }
        refreshPicker()
    }

    /// `Remove from List`: the registry entry only, never the file; undoable this session.
    @discardableResult
    func removeFromList(_ row: LibraryPickerRow) -> Bool {
        switch row.kind {
        case .unlisted:
            unlisted.removeAll { $0.url.standardizedFileURL.path == row.url.standardizedFileURL.path }
            refreshPicker()
            return true
        case .legacy, .interruptedSetup:
            return false
        case .registered(let libraryId):
            guard var registry = try? store.load(now: now()).registry,
                  let removal = registry.remove(libraryId: libraryId) else { return false }
            do {
                try store.save(registry)
            } catch {
                AppLogger.shared.error("Removing a library from the list failed: \(error)", source: "Library")
                return false
            }
            lastRemoval = removal
            rowNotes[row.id] = nil
            if pickerFocus?.url.standardizedFileURL.path == row.url.standardizedFileURL.path { pickerFocus = nil }
            refreshRegistryState(registry)
            return true
        }
    }

    /// `Undo` on the picker's status line.
    func undoRemoval() {
        guard let removal = lastRemoval, var registry = try? store.load(now: now()).registry else { return }
        registry.reinsert(removal)
        do {
            try store.save(registry)
            lastRemoval = nil
            refreshRegistryState(registry)
        } catch {
            AppLogger.shared.error("Putting a library back on the list failed: \(error)", source: "Library")
        }
    }

    /// The picker's status line after `Remove from List`.
    var removalMessage: String? {
        lastRemoval.map { "Removed “\($0.entry.displayName)” from the list — the library file is unchanged." }
    }

    // MARK: Library file panel (S-LIBFILE-OPEN)

    /// `Open Other…` / File ▸ `Open Library…` / footer `Open Library…`.
    func chooseLibraryFile() {
        guard !isBusy else { return }
        libraryFileRequest = LibraryFileRequest(purpose: .open)
    }

    /// `Locate…` on a Not found row.
    func locate(_ row: LibraryPickerRow) {
        libraryFileRequest = LibraryFileRequest(purpose: .locate(rowID: row.id))
    }

    func cancelLibraryFile() {
        libraryFileRequest = nil
    }

    /// The panel's answer.
    func libraryFileChosen(_ url: URL) async {
        guard let request = libraryFileRequest.take() else { return }
        switch request.purpose {
        case .open:
            await handleOpen(url)
        case .locate(let rowID):
            guard let row = pickerRows.first(where: { $0.id == rowID }) else { return await handleOpen(url) }
            await locate(row, at: url)
        }
    }

    /// A file with the same library id re-points the entry (A0 D1) and opens; another library
    /// is refused on the row.
    func locate(_ row: LibraryPickerRow, at chosen: URL) async {
        let chosen = Self.canonical(chosen)
        guard case .registered(let libraryId) = row.kind,
              let chosenId = try? LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: chosen))
        else {
            await handleOpen(chosen)
            return
        }
        guard chosenId == libraryId else {
            rowNotes[row.id] = "“\(chosen.lastPathComponent)” is a different library. Locate “\(row.name)”, or remove it from this list."
            return
        }
        rowNotes[row.id] = nil
        await handleOpen(chosen)
    }

    // MARK: - Open / create (nothing open yet)

    /// Open a library file while no library is open (launch, picker, `Open Other…`, a drop).
    func open(packageAt url: URL) async {
        let url = Self.canonical(url)
        lastRemoval = nil
        startOpen(name: displayName(forPackage: url), phase: .checking)
        switch prepare(packageAt: url) {
        case .ready(let location, let name):
            await finishOpening(location, name: name)
        case .problem(let problem):
            showLaunchProblem(problem)
        case .failure(let failure):
            screen = .failed(failure)
        }
    }

    /// A launch problem: a row of the picker, the invalid state, or the copy alert.
    private func showLaunchProblem(_ problem: Problem) {
        switch problem {
        case .unavailable(let name, let url, let availability):
            if (try? store.load(now: now()).registry.entry(at: url)) == nil {
                let state: LibraryPickerRow.State = availability == .notConnected
                    ? .notConnected(volume: LibraryPickerRows.volumeName(of: url) ?? "")
                    : .notFound
                remember(UnlistedLibraryProblem(url: url, name: name, state: state))
            }
            showPicker(focus: PickerFocus(name: name, url: url))
        case .mismatch(let name, let url, let details):
            mismatches[url.standardizedFileURL.path] = details
            if (try? store.load(now: now()).registry.entry(at: url)) == nil {
                remember(UnlistedLibraryProblem(url: url, name: name, state: .mismatch(details: details)))
            }
            showPicker(focus: PickerFocus(name: name, url: url))
        case .invalid(let file):
            screen = .invalid(file)
        case .duplicateCopy, .creationFailed, .listNotSaved, .refused:
            showPicker()
            switchProblem = problem
        }
    }

    private func remember(_ problem: UnlistedLibraryProblem) {
        unlisted.removeAll { $0.url.standardizedFileURL.path == problem.url.standardizedFileURL.path }
        unlisted.insert(problem, at: 0)
    }

    /// `Try Again` on the failed state.
    func retryFailedOpen() async {
        guard case .failed(let failure) = screen, !isBusy else { return }
        closeRestore()
        switch failure.location {
        case .package(let url)?:
            await open(packageAt: url)
        case .legacy(let url)?:
            await finishOpening(.legacy(url), name: failure.name)
        case nil:
            await start()
        }
    }

    /// `Choose Another Library` (failed, invalid).
    func chooseAnotherLibrary() {
        guard !isBusy else { return }
        closeRestore()
        showPicker()
    }

    /// `New Library…` (menu, footer, picker).
    func requestNewLibrary(named name: String = "New Library") {
        // The first run's step 1 is the form already.
        guard screen != .firstRunSetup, !isBusy else { return }
        switchProblem = nil
        newLibraryRequest = NewLibraryRequest(defaultName: name)
    }

    func cancelNewLibrary() {
        newLibraryRequest = nil
    }

    /// Checks a new library's name and location before anything is created.
    func newLibraryProblem(named name: String, in directory: URL? = nil) -> NewLibraryError? {
        Self.newLibraryProblem(named: name, in: directory ?? store.librariesDirectory)
    }

    /// The same check, for a background task (the forms check while typing, off the main
    /// actor — N5).
    nonisolated static func newLibraryProblem(named name: String, in directory: URL) -> NewLibraryError? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .emptyName }
        let package = directory.appendingPathComponent(LibraryPackage.fileName(forLibraryName: name))
        if FileManager.default.fileExists(atPath: package.path) { return .nameTaken(name) }
        if !isWritable(directory) { return .notWritable(folder: directory.lastPathComponent) }
        return nil
    }

    /// `Create` (S-NEWLIB) / `Create Library` (V-SETUP step 1). Errors come back for the form.
    /// No library open: the library is created and opened, then the setup continues with the
    /// library folder. A library open: `Switch to “‹name›”?` — created only once confirmed.
    @discardableResult
    func createLibrary(named name: String, in directory: URL? = nil) async -> NewLibraryError? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = directory ?? store.librariesDirectory
        if let busyReason { return .busy(busyReason) }
        if let problem = newLibraryProblem(named: name, in: directory) { return problem }
        if screen == .opened {
            newLibraryRequest = nil
            pendingSwitch = SwitchRequest(name: name, target: .create(directory: directory))
            return nil
        }
        let package: URL
        do {
            package = Self.canonical(try LibraryPackage.createEmpty(
                named: name, libraryId: UUID().uuidString.lowercased(), in: directory, now: now()))
        } catch {
            AppLogger.shared.error("Creating a library failed: \(error)", source: "Library")
            return .failed(name: name, cause: Self.plainCause(error))
        }
        newLibraryRequest = nil
        await open(packageAt: package)
        return nil
    }

    /// `Done`, `Continue in Background` on the setup.
    func endSetup() {
        setup = nil
    }

    /// `Set Up Later`: leaves an empty All Tracks and isn't asked again for this library at
    /// the next launch (THOUGHTS §7.18, review S8) — until a library folder is set.
    func setUpLater() async {
        await setup?.setUpLater()
        setup = nil
    }

    // MARK: - Adoption (A0 D7)

    /// `Set Up…` on the old install's row.
    func offerAdoption() {
        guard FileManager.default.fileExists(atPath: legacyDatabaseURL.path) else { return }
        adoptionState = .idle
        adoptionOffer = true
    }

    /// `Create Library File`. Runs off the main thread; the legacy database is not open.
    func adoptLegacyLibrary(named name: String) async {
        // One at a time (N1); never while a restore runs.
        guard !isBusy else { return }
        adoptingName = name
        lastAdoptionError = nil
        adoptionState = .running(.backingUp)
        let adoption = self.adoption
        // Activity (W3-ACT): app-level `Create library file “‹name›”` (no library is open yet);
        // the phases show in the adoption sheet; no Cancel while it runs.
        let job = ActivityCenter.shared.begin(.libraryAdoption, title: "Create library file “\(name)”",
                                              subject: .libraryFile, appLevel: true)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try adoption.adopt(named: name) { phase in
                    Task { @MainActor in self.updateAdoptionPhase(phase) }
                }
            }.value
            adoptionState = .succeeded(result)
            job.finish(ActivityResult(summary: "Old install adopted · backup “Before library file setup”"))
        } catch {
            AppLogger.shared.error("Library file setup failed: \(error)", source: "Library")
            job.fail(cause: "The library file couldn’t be created — your music and the old library are not affected")
            if let package = adoption.installedPackageURL() {
                // Past the point of no return: the library file is complete. Open it; the
                // remaining steps finish at the next launch.
                adoptionOffer = false
                adoptionState = .idle
                let package = Self.canonical(package)
                await finishOpening(.package(package), name: displayName(forPackage: package))
            } else {
                lastAdoptionError = String(describing: error)
                adoptionState = .failed(details: String(describing: error))
                // A rollback that failed too leaves the journal: the picker shows the
                // interrupted setup instead of the old install (S3).
                if screen == .picker { refreshPicker() }
            }
        }
    }

    /// `Done` on the success message: opens the new library file.
    func finishAdoption() async {
        guard case .succeeded(let result) = adoptionState else { return }
        adoptionState = .idle
        adoptionOffer = false
        let package = Self.canonical(result.packageURL)
        await finishOpening(.package(package), name: displayName(forPackage: package))
    }

    /// `Not Now` — back to the picker, where the old install is listed as
    /// `Main Library (needs setup)`; it is asked again at the next launch. Never opens anything
    /// by itself (fixes ROADMAP A3 note 13).
    func declineAdoption() async {
        guard !adoptionState.isRunning else { return }
        adoptionState = .idle
        adoptionOffer = false
        if screen == .picker { refreshPicker() }
        await drainQueuedOpen()
    }

    private func updateAdoptionPhase(_ phase: LibraryAdoption.Phase) {
        if case .running = adoptionState { adoptionState = .running(phase) }
    }

    /// An adoption was interrupted: finish it (past the rename) or undo it and ask again.
    private func resumeAdoption() async {
        let adoption = self.adoption
        let name = adoption.pendingName() ?? LibraryPickerRows.legacyName
        startOpen(name: name, phase: .finishingSetup)
        do {
            let outcome = try await Task.detached(priority: .userInitiated) { try adoption.resume() }.value
            switch outcome {
            case .completed(let result):
                AppLogger.shared.info("Finished interrupted library file setup: \(result.packageURL.path)", source: "Library")
                let package = Self.canonical(result.packageURL)
                await finishOpening(.package(package), name: displayName(forPackage: package))
            case .rolledBack:
                AppLogger.shared.info("Undid interrupted library file setup", source: "Library")
                await resolveAndOpen(openedFileURL: nil)
            }
        } catch {
            AppLogger.shared.error("Resuming library file setup failed: \(error)", source: "Library")
            if let package = adoption.installedPackageURL() {
                let package = Self.canonical(package)
                await finishOpening(.package(package), name: displayName(forPackage: package))
            } else {
                reportFailure(error)
                lastAdoptionError = String(describing: error)
                screen = .failed(LaunchFailure(
                    name: name, location: nil, cause: .setupInterrupted, details: String(describing: error)))
            }
        }
    }

    // MARK: - Switch (a library is open)

    /// Make `url` the library to open and relaunch into it. Validates first, so a
    /// problem is reported without quitting.
    func switchLibrary(to url: URL) -> SwitchOutcome {
        let url = Self.canonical(url)
        switch prepare(packageAt: url) {
        case .ready(let location, _):
            // A running duplicate scan belongs to this library: cancelled, nothing kept (IMP-108).
            ReviewScanRunner.shared.libraryDidChange()
            pendingOpen.set(location.packageURL?.path ?? url.path)
            relaunch()
            return .relaunching
        case .problem(let problem):
            return .failed(problem)
        case .failure(let failure):
            return .failed(.listNotSaved(name: failure.name))
        }
    }

    // MARK: - Restore at launch (S-LAUNCH-RESTORE)

    /// Prepares `Restore from Backup…` for the failed library, when it has backups.
    func loadRestoreOptions() async {
        guard case .failed(let failure) = screen, failure.mayOfferRestore, restore == nil,
              let location = failure.location else { return }
        let expectedId: String? = location.packageURL.flatMap { package in
            (try? store.load(now: now()).registry.entry(at: package)?.libraryId)
                ?? (try? LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package)).libraryId)
        }
        let pendingOpen = self.pendingOpen
        let relaunch = self.relaunch
        let model = await LaunchRestoreModel.make(
            databaseURL: location.databaseURL,
            expectedLibraryId: expectedId,
            libraryName: failure.name,
            backupsRoot: adoption.environment.backupsRoot,
            relaunch: {
                // Reopen the restored library after the relaunch.
                if let package = location.packageURL { pendingOpen.set(package.path) }
                relaunch()
            }
        )
        // The screen may have moved on meanwhile.
        guard case .failed(let current) = screen, current == failure else {
            model?.close()
            return
        }
        restore = model
    }

    /// Releases the failed library's database. Never while its restore runs (S1): nothing
    /// that would reach here can start then, and the model stays until the restore ends.
    private func closeRestore() {
        guard !isRestoreRunning, let model = restore else { return }
        model.close()
        restore = nil
    }

    /// `Restore and Relaunch` in S-LAUNCH-RESTORE: the existing restore. While it runs no
    /// library can be opened, created or switched to (S1); a library file opened meanwhile
    /// waits and is handled if the restore fails (on success MLM relaunches).
    func restoreFromBackup(_ info: BackupInfo) async {
        guard let model = restore, !isBusy else { return }
        markRestoreRunning(true)
        await model.restore(info)
        // Restored: MLM is relaunching (or must, after a failed swap) — stay busy, open nothing.
        if model.backups.phase == .relaunching || model.backups.isRelaunchRequired { return }
        markRestoreRunning(false)
        await drainQueuedOpen()
    }

    /// The restore's busy state (also what the tests drive).
    func markRestoreRunning(_ running: Bool) {
        isRestoreRunning = running
    }

    // MARK: - Internals

    /// Library file URLs without a trailing slash, so locations compare by path.
    private static func canonical(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path, directoryHint: .notDirectory)
    }

    /// The name to show for a library file: the list's, else its manifest's, else the file's.
    func displayName(forPackage url: URL) -> String {
        if let entry = try? store.load(now: now()).registry.entry(at: url) { return entry.displayName }
        if let manifest = try? LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: url)),
           !manifest.name.isEmpty {
            return manifest.name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private enum Preparation {
        case ready(LibraryLocation, name: String)
        case problem(Problem)
        case failure(LaunchFailure)
    }

    /// The loading screen for a new open, with its first phase.
    private func startOpen(name: String, phase: LibraryOpenPhase) {
        openGeneration += 1
        openPhases = [phase]
        screen = .loading(Loading(name: name, phase: phase))
    }

    private func applyPhase(_ phase: LibraryOpenPhase, generation: Int) {
        guard generation == openGeneration, case .loading(var loading) = screen else { return }
        openPhases.append(phase)
        loading.phase = phase
        screen = .loading(loading)
    }

    private func finishOpening(_ location: LibraryLocation, name: String) async {
        guard !isRestoreRunning else { return }
        closeRestore()
        if case .loading = screen {
            applyPhase(.reading, generation: openGeneration)
        } else {
            startOpen(name: name, phase: .reading)
        }
        let generation = openGeneration
        let phasesBefore = openPhases
        // Every reported phase, in the order the open path reported them (exact, whatever the
        // main queue got to show) — for `openPhases`. The failure sentence follows the error's
        // own step (`LibraryOpenError`), not the last phase (S7).
        let reported = Mutex<[LibraryOpenPhase]>([])
        let progress: LibraryOpenProgress = { [weak self] phase in
            reported.withLock { $0.append(phase) }
            // The loading screen follows live; main-queue order is the reporting order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPhase(phase, generation: generation) }
            }
        }
        defer {
            if generation == openGeneration { openPhases = phasesBefore + reported.withLock { $0 } }
        }
        do {
            try await openLibrary(location, progress)
            activePackageURL = location.packageURL
            if let registry = try? store.load(now: now()).registry {
                activeLibraryId = location.packageURL.flatMap { registry.entry(at: $0)?.libraryId }
                refreshRegistryState(registry)
            }
            pickerFocus = nil
            if await needsSetup() {
                setup = LibrarySetupModel(libraryName: name, services: setupServices)
            }
            screen = .opened
            await drainQueuedOpen()
        } catch {
            reportFailure(error)
            screen = .failed(LaunchFailure(
                name: name,
                location: location,
                cause: LaunchFailure.cause(for: error),
                details: "\(error)\n\((location.databaseURL.path as NSString).abbreviatingWithTildeInPath)"))
        }
    }

    /// Validate the library file, give a manually built one its identity, and record it in
    /// the registry as the last opened library. Never changes anything on a mismatch.
    private func prepare(packageAt url: URL) -> Preparation {
        let fileName = url.deletingPathExtension().lastPathComponent
        var registry: LibraryRegistry
        do {
            registry = try store.load(now: now()).registry
        } catch {
            return .failure(LaunchFailure(
                name: fileName, location: nil,
                cause: .libraryList(newerVersion: error is LibraryRegistryStore.LoadError),
                details: "\(error)\n\(store.fileURL.path)"))
        }
        // A symlink (or alias path) to a listed library is that library, at its listed path
        // (N3): never a copy, never re-pointed.
        let resolved = url.resolvingSymlinksInPath().path
        let url = registry.entry(at: url)?.url
            ?? registry.libraries.first { $0.url.resolvingSymlinksInPath().path == resolved }?.url
            ?? url
        let registeredAtPath = registry.entry(at: url)
        let displayName = registeredAtPath?.displayName ?? fileName

        let validated: LibraryPackage.Validated
        do {
            validated = try validateAssigningIdIfNeeded(url, expectedLibraryId: registeredAtPath?.libraryId)
        } catch LibraryPackage.ValidationError.notFound {
            return .problem(.unavailable(name: displayName, url: url, availability: LibraryRegistry.availability(of: url)))
        } catch LibraryPackage.ValidationError.idMismatch(let expected, let found) {
            return .problem(.mismatch(name: displayName, url: url, details: Self.mismatchDetails(expected: expected, found: found)))
        } catch LibraryPackage.ValidationError.missingDatabase {
            return .problem(.invalid(InvalidLibraryFile(
                url: url, cause: .noDatabase, details: Self.invalidDetails(url, "music_library.db: missing"))))
        } catch LibraryPackage.ValidationError.unsupportedManifestVersion(let version) {
            return .problem(.invalid(InvalidLibraryFile(
                url: url, cause: .newerVersion, details: Self.invalidDetails(url, "library.json: manifest_version \(version)"))))
        } catch {
            return .problem(.invalid(InvalidLibraryFile(
                url: url, cause: .unreadable, details: Self.invalidDetails(url, "\(error)"))))
        }

        let libraryId = validated.manifest.libraryId
        // A Finder copy carries its original's id while the original still exists. Paths are
        // compared resolved, so a symlink to the original is never taken for a copy (N3).
        if let other = registry.entry(withId: libraryId),
           other.url.resolvingSymlinksInPath().path != url.resolvingSymlinksInPath().path,
           FileManager.default.fileExists(atPath: other.url.path) {
            return .problem(.duplicateCopy(name: fileName, originalName: other.displayName, url: url))
        }

        registry.upsert(libraryId: libraryId, url: url, name: validated.manifest.name)
        registry.markOpened(libraryId: libraryId, at: now())
        do {
            try store.save(registry)
        } catch {
            return .failure(LaunchFailure(
                name: validated.manifest.name, location: nil, cause: .libraryList(newerVersion: false),
                details: "\(error)\n\(store.fileURL.path)"))
        }
        mismatches[url.standardizedFileURL.path] = nil
        unlisted.removeAll { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
        return .ready(.package(url), name: validated.manifest.name.isEmpty ? fileName : validated.manifest.name)
    }

    /// A library file built by hand (legacy migration guide step 3) may hold a database
    /// without `library_id`; it gets a new one once, then validation repairs the manifest.
    private func validateAssigningIdIfNeeded(_ url: URL, expectedLibraryId: String?) throws -> LibraryPackage.Validated {
        do {
            return try LibraryPackage.validate(at: url, expectedLibraryId: expectedLibraryId, now: now())
        } catch LibraryPackage.ValidationError.missingLibraryId where expectedLibraryId == nil {
            try LibraryPackage.assignLibraryId(UUID().uuidString.lowercased(), toDatabaseIn: url)
            return try LibraryPackage.validate(at: url, expectedLibraryId: nil, now: now())
        }
    }

    private static func mismatchDetails(expected: String, found: String) -> String {
        "Expected library ID  \(expected)  (library.json or list of libraries)\nDatabase library ID  \(found)  (app_config.library_id)"
    }

    private static func invalidDetails(_ url: URL, _ line: String) -> String {
        "\((url.path as NSString).abbreviatingWithTildeInPath)\n\(line)"
    }

    /// The folder (or its nearest existing parent) can be written.
    nonisolated static func isWritable(_ directory: URL) -> Bool {
        var url = directory.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    /// A creation error in plain words (no codes).
    static func plainCause(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    /// A-LIBFILE-INVALID.N01 message.
    static func creationFailureMessage(_ error: Error, folder: URL) -> String {
        let nsError = error as NSError
        let permission = [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(nsError.code)
            || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EROFS), Int(EPERM)].contains(nsError.code))
        if permission {
            return "MLM can’t write to “\(folder.lastPathComponent)”. Choose another location and try again. Nothing was added to your libraries."
        }
        return "\(plainCause(error)) Nothing was added to your libraries."
    }
}

extension LibraryLaunchCoordinator.AdoptionState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

extension LibraryRegistry.Entry {
    /// Display name of an entry; falls back to the file name.
    var displayName: String { name.isEmpty ? url.deletingPathExtension().lastPathComponent : name }
}

private extension Optional {
    /// Returns the value and clears the optional.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
