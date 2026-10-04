import Foundation
import Observation

/// Chooses and opens the library at launch, before the dependency container exists, and
/// switches libraries by relaunching (A3 Step-0 decision 1).
///
/// Flow: resolver decision → validate the library file → update the registry → hand the
/// location to `openLibrary` (the container). Anything that needs the user ends in a
/// `screen` the root view shows instead of the library.
@MainActor
@Observable
final class LibraryLaunchCoordinator {

    /// What the window shows while no library is open.
    enum Screen: Equatable {
        case resolving
        case opened
        /// `No library open` — the user creates or opens one.
        case noLibrary
        /// First run: `New Library` sheet with "Main Library", then the first-run wizard.
        case createFirstLibrary
        /// `Set up your library file` — the pre-A3 install can be adopted.
        case offerAdoption
        /// `"‹name›" can't be opened` — not found / not connected.
        case unavailable(LibraryRegistry.Entry, LibraryAvailability)
        /// `"‹name›" can't be opened` — identity differs from its database or the registry.
        case mismatch(name: String, packageURL: URL)
        /// `"‹name›" isn't a valid library file.`
        case invalid(name: String)
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
        case failed(Screen)
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

    let store: LibraryRegistryStore
    private let adoption: LibraryAdoption
    private var legacyDatabaseURL: URL { adoption.environment.legacyDatabaseURL }
    private let now: () -> Date
    private let pendingOpen: PendingOpenStore
    private let openLibrary: (LibraryLocation) async throws -> Void
    private let reportFailure: (Error) -> Void
    private let relaunch: () -> Void

    init(
        store: LibraryRegistryStore = LibraryRegistryStore(),
        adoption: LibraryAdoption,
        now: @escaping () -> Date = { Date() },
        pendingOpen: PendingOpenStore = .userDefaults,
        openLibrary: @escaping (LibraryLocation) async throws -> Void,
        reportFailure: @escaping (Error) -> Void,
        relaunch: @escaping () -> Void
    ) {
        self.store = store
        self.adoption = adoption
        self.now = now
        self.pendingOpen = pendingOpen
        self.openLibrary = openLibrary
        self.reportFailure = reportFailure
        self.relaunch = relaunch
    }

    /// The app's coordinator: opens libraries into `DependencyContainer.shared`.
    static let shared = LibraryLaunchCoordinator(
        adoption: LibraryAdoption(),
        openLibrary: { location in try await DependencyContainer.shared.initialize(location: location) },
        reportFailure: { error in DependencyContainer.shared.reportInitializationFailure(error) },
        relaunch: { BackupService.relaunchApp() }
    )

    // MARK: - Launch

    /// Resolve and open the library for this launch.
    ///
    /// - Parameter openedFileURL: a library file the user opened to launch the app.
    func start(openedFileURL: URL? = nil) async {
        screen = .resolving
        let registry: LibraryRegistry
        do {
            registry = try store.load(now: now()).registry
        } catch {
            reportFailure(error)
            return
        }

        let pending = pendingOpen.take().map { URL(fileURLWithPath: $0) }
        let decision = LibraryLaunchResolver.resolve(.init(
            registry: registry,
            legacyDatabaseExists: FileManager.default.fileExists(atPath: legacyDatabaseURL.path),
            adoptionInProgress: adoption.isInProgress,
            openedFileURL: openedFileURL ?? pending,
            availability: { LibraryRegistry.availability(of: $0) }
        ))

        switch decision {
        case .openPackage(let url, _):
            await open(packageAt: url)
        case .offerAdoption:
            adoptionState = .idle
            screen = .offerAdoption
        case .resumeAdoption:
            await resumeAdoption()
        case .createFirstLibrary:
            screen = .createFirstLibrary
        case .noLibrary:
            screen = .noLibrary
        case .libraryUnavailable(let entry, let availability):
            screen = .unavailable(entry, availability)
        }
    }

    /// `Try again` on an unavailable library.
    func retry() async {
        await start()
    }

    /// `OK` on a mismatch / invalid screen.
    func dismissProblem() {
        screen = .noLibrary
    }

    // MARK: - Open / create (nothing open yet)

    /// Open a library file while no library is open (launch, `Open Library…` on a launch screen).
    func open(packageAt url: URL) async {
        switch prepare(packageAt: Self.canonical(url)) {
        case .ready(let location):
            await finishOpening(location)
        case .problem(let problem):
            screen = problem
        }
    }

    /// `New Library` sheet → create in the default folder, register, open.
    func createLibrary(named name: String) async {
        do {
            let package = try LibraryPackage.createEmpty(
                named: name,
                libraryId: UUID().uuidString.lowercased(),
                in: store.librariesDirectory,
                now: now()
            )
            await open(packageAt: package)
        } catch {
            reportFailure(error)
        }
    }

    // MARK: - Adoption (A0 D7)

    /// `Create library file`. Runs off the main thread; the legacy database is not open.
    func adoptLegacyLibrary(named name: String) async {
        adoptionState = .running(.backingUp)
        let adoption = self.adoption
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try adoption.adopt(named: name) { phase in
                    Task { @MainActor in self.updateAdoptionPhase(phase) }
                }
            }.value
            adoptionState = .succeeded(result)
        } catch {
            AppLogger.shared.error("Library file setup failed: \(error)", source: "Library")
            if let package = adoption.installedPackageURL() {
                // Past the point of no return: the library file is complete. Open it; the
                // remaining steps finish at the next launch.
                await finishOpening(.package(package))
            } else {
                adoptionState = .failed(details: String(describing: error))
            }
        }
    }

    /// `Done` on the success message.
    func finishAdoption() async {
        guard case .succeeded(let result) = adoptionState else { return }
        adoptionState = .idle
        await finishOpening(.package(Self.canonical(result.packageURL)))
    }

    /// `Not now` — the old layout keeps working; MLM asks again at the next launch.
    func declineAdoption() async {
        adoptionState = .idle
        await finishOpening(.legacy(legacyDatabaseURL))
    }

    private func updateAdoptionPhase(_ phase: LibraryAdoption.Phase) {
        if case .running = adoptionState { adoptionState = .running(phase) }
    }

    /// An adoption was interrupted: finish it (past the rename) or undo it and ask again.
    private func resumeAdoption() async {
        let adoption = self.adoption
        do {
            let outcome = try await Task.detached(priority: .userInitiated) { try adoption.resume() }.value
            switch outcome {
            case .completed(let result):
                AppLogger.shared.info("Finished interrupted library file setup: \(result.packageURL.path)", source: "Library")
                await finishOpening(.package(Self.canonical(result.packageURL)))
            case .rolledBack:
                AppLogger.shared.info("Undid interrupted library file setup", source: "Library")
                await start()
            }
        } catch {
            AppLogger.shared.error("Resuming library file setup failed: \(error)", source: "Library")
            if let package = adoption.installedPackageURL() {
                await finishOpening(.package(package))
            } else {
                reportFailure(error)
            }
        }
    }

    // MARK: - Switch (a library is open)

    /// Make `url` the library to open and relaunch into it. Validates first, so a
    /// problem is reported without quitting.
    func switchLibrary(to url: URL) -> SwitchOutcome {
        let url = Self.canonical(url)
        switch prepare(packageAt: url) {
        case .ready:
            pendingOpen.set(url.path)
            relaunch()
            return .relaunching
        case .problem(let problem):
            return .failed(problem)
        }
    }

    // MARK: - Internals

    /// Library file URLs without a trailing slash, so locations compare by path.
    private static func canonical(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path, directoryHint: .notDirectory)
    }

    private enum Preparation {
        case ready(LibraryLocation)
        case problem(Screen)
    }

    private func finishOpening(_ location: LibraryLocation) async {
        do {
            try await openLibrary(location)
            screen = .opened
        } catch {
            reportFailure(error)
        }
    }

    /// Validate the library file, give a manually built one its identity, and record it in
    /// the registry as the last opened library. Never changes anything on a mismatch.
    private func prepare(packageAt url: URL) -> Preparation {
        let displayName = url.deletingPathExtension().lastPathComponent
        var registry: LibraryRegistry
        do {
            registry = try store.load(now: now()).registry
        } catch {
            return .problem(.invalid(name: displayName))
        }
        let registeredAtPath = registry.entry(at: url)

        let validated: LibraryPackage.Validated
        do {
            validated = try validateAssigningIdIfNeeded(url, expectedLibraryId: registeredAtPath?.libraryId)
        } catch LibraryPackage.ValidationError.notFound {
            let entry = registeredAtPath ?? LibraryRegistry.Entry(
                libraryId: "", path: url.path, name: displayName, lastOpenedAt: nil)
            return .problem(.unavailable(entry, LibraryRegistry.availability(of: url)))
        } catch LibraryPackage.ValidationError.idMismatch {
            return .problem(.mismatch(name: displayName, packageURL: url))
        } catch {
            return .problem(.invalid(name: displayName))
        }

        let libraryId = validated.manifest.libraryId
        // A Finder copy carries its original's id while the original still exists.
        if let other = registry.entry(withId: libraryId),
           other.url.standardizedFileURL.path != url.standardizedFileURL.path,
           FileManager.default.fileExists(atPath: other.url.path) {
            return .problem(.mismatch(name: displayName, packageURL: url))
        }

        registry.upsert(libraryId: libraryId, url: url, name: validated.manifest.name)
        registry.markOpened(libraryId: libraryId, at: now())
        do {
            try store.save(registry)
        } catch {
            return .problem(.invalid(name: displayName))
        }
        return .ready(.package(url))
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
}

extension LibraryRegistry.Entry {
    /// Display name of an entry; falls back to the file name.
    var displayName: String { name.isEmpty ? url.deletingPathExtension().lastPathComponent : name }
}
