import Foundation

/// `Rename…` of the open library (S-SET-RENAMELIB, A0 D1): the library's name, its library file
/// (`<name>.mlibm`, same folder) and its entry in the list of libraries change together.
///
/// Built with the care of adoption: every step is checked and undone in reverse order when a
/// later one fails, so a failed rename leaves the library file, its manifest, the list and the
/// path-migration records exactly as they were.
///
/// 1. Check the name (not empty, not the same, no other file of that name in the folder).
/// 2. Write the new name into the manifest.
/// 3. Move the library file (`<old>.mlibm` → `<new>.mlibm`; a change of letter case goes through
///    a temporary name).
/// 4. Verify: the manifest at the new place reads with the same library id, the database is there.
/// 5. Re-point the list of libraries (`libraries.json`).
/// 6. Re-point path-migration records, so `Roll Back Last Migration…` stays available.
///
/// The open library's database lives inside the file, so the app closes it first and relaunches
/// into the renamed file (one library per process, A0 D4) — see `SettingsLibraryModel`.
enum LibraryRename {

    enum Problem: Error, Equatable {
        case emptyName
        case sameName
        /// `A library file named “‹file›” already exists in that folder. Choose another name.`
        case nameTaken(fileName: String)
        /// Something failed; nothing was changed (or everything was put back).
        case failed(detail: String)
        /// Work is running (a rename relaunches MLM): the sentence lists it.
        case workRunning(String)
        /// Another library in the list already uses that library file (it would be dropped).
        case listedElsewhere(fileName: String)

        /// The inline sentence above the sheet's buttons (UC-SHEET-05).
        var message: String {
            switch self {
            case .emptyName: "Enter a name for the library."
            case .sameName: "The library already has this name."
            case .nameTaken(let file): "A library file named “\(file)” already exists in that folder. Choose another name."
            case .failed: "The library couldn’t be renamed. Nothing was changed."
            case .workRunning(let text): text
            case .listedElsewhere(let file): "Another library in the list uses “\(file)”. Choose another name."
            }
        }
    }

    /// `<folder>/<new name>.mlibm`.
    static func targetURL(for package: URL, newName: String) -> URL {
        package.deletingLastPathComponent()
            .appendingPathComponent(LibraryPackage.fileName(forLibraryName: newName))
    }

    /// Why `newName` can't be used now, or `nil`.
    static func problem(
        newName: String,
        currentName: String,
        package: URL,
        fileManager: FileManager = .default
    ) -> Problem? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyName }
        let target = targetURL(for: package, newName: trimmed)
        if trimmed == currentName, target.lastPathComponent == package.lastPathComponent { return .sameName }
        if !isSameFile(target, package), fileManager.fileExists(atPath: target.path) {
            return .nameTaken(fileName: target.lastPathComponent)
        }
        return nil
    }

    /// Renames and returns the new library file URL. Throws `Problem`; on `.failed` every step
    /// that was done has been undone.
    @discardableResult
    static func rename(
        package: URL,
        to newName: String,
        libraryId: String,
        store: LibraryRegistryStore,
        pathMigrationsDirectory: URL = OrganizedPathMigrationService.defaultArtifactsDirectory(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentManifestURL = LibraryPackage.manifestURL(in: package)
        let original: LibraryPackageManifest
        do {
            original = try LibraryPackageManifest.read(from: currentManifestURL)
        } catch {
            throw Problem.failed(detail: "manifest unreadable: \(error)")
        }
        guard original.libraryId == libraryId else {
            throw Problem.failed(detail: "manifest belongs to another library")
        }
        if let problem = problem(newName: name, currentName: original.name, package: package, fileManager: fileManager) {
            throw problem
        }
        let target = targetURL(for: package, newName: name)
        // Never drop another library's list entry at the target (`upsert` would replace it).
        let (listed, _) = (try? store.load()) ?? (LibraryRegistry(), .loaded)
        if let other = listed.entry(at: target), other.libraryId != libraryId, !isSameFile(target, package) {
            throw Problem.listedElsewhere(fileName: target.lastPathComponent)
        }
        var undo: [() -> Void] = []
        func rollBack() { for step in undo.reversed() { step() } }

        // Where the library file is now (rollback writes the manifest back there).
        var location = package
        do {
            // 2. Manifest name.
            var renamed = original
            renamed.name = name
            try renamed.write(to: currentManifestURL)
            undo.append { try? original.write(to: LibraryPackage.manifestURL(in: location)) }

            // 3. The library file.
            if target.path != package.path {
                try move(package, to: target, fileManager: fileManager)
                location = target
                undo.append {
                    if (try? move(target, to: package, fileManager: fileManager)) != nil { location = package }
                }
            }

            // 4. Verify.
            let moved = try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: target))
            guard moved.libraryId == libraryId, moved.name == name,
                  fileManager.fileExists(atPath: LibraryPackage.databaseURL(in: target).path) else {
                throw Problem.failed(detail: "verification failed")
            }

            // 5. The list of libraries.
            let (registry, _) = try store.load()
            var updated = registry
            updated.upsert(libraryId: libraryId, url: target, name: name)
            try store.save(updated)
            undo.append { try? store.save(registry) }

            // 6. Path-migration records follow the database.
            let oldDatabase = LibraryPackage.databaseURL(in: package)
            let newDatabase = LibraryPackage.databaseURL(in: target)
            if oldDatabase.path != newDatabase.path {
                // Registered first (review S6): a re-point that fails half-way is undone too —
                // pointing the records back is harmless for those that weren't changed.
                undo.append {
                    _ = try? OrganizedPathMigrationService.repointManifests(
                        in: pathMigrationsDirectory, fromDatabase: newDatabase, to: oldDatabase, fileManager: fileManager)
                }
                try OrganizedPathMigrationService.repointManifests(
                    in: pathMigrationsDirectory, fromDatabase: oldDatabase, to: newDatabase, fileManager: fileManager)
            }
            return target
        } catch let problem as Problem {
            rollBack()
            throw problem
        } catch {
            rollBack()
            throw Problem.failed(detail: String(describing: error))
        }
    }

    /// Moves a library file; a change of letter case only goes through a temporary name
    /// (case-insensitive volumes).
    private static func move(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        guard isSameFile(source, destination) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let temp = source.deletingLastPathComponent()
            .appendingPathComponent(".rename-\(UUID().uuidString).\(LibraryPackage.fileExtension)")
        try fileManager.moveItem(at: source, to: temp)
        do {
            try fileManager.moveItem(at: temp, to: destination)
        } catch {
            try? fileManager.moveItem(at: temp, to: source)
            throw error
        }
    }

    /// Two paths that name the same file (they differ only in letter case on this volume).
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        // Letter case and Unicode normalisation (NFC / NFD) only.
        func folded(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard folded(a) == folded(b) else { return false }
        let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let idA, let idB else { return false }
        return idA.isEqual(idB)
    }

    // MARK: - Renaming the open library

    enum Outcome: Equatable {
        /// Renamed; MLM relaunches into the renamed file.
        case relaunching(URL)
        /// Nothing happened; the sheet says why (UC-SHEET-05).
        case refused(Problem)
        /// The database was closed but the rename failed and was undone: MLM must relaunch
        /// (`Rename didn’t finish` · `Relaunch`).
        case relaunchRequired
    }

    /// The whole S-SET-RENAMELIB action for the open library: refused while work runs (a rename
    /// relaunches MLM), then the database is closed, the file renamed and MLM relaunches into it
    /// (the pending open makes it open even when “Open the last library at launch” is off).
    @MainActor
    static func renameOpenLibrary(
        package: URL,
        currentName: String,
        to newName: String,
        libraryId: String,
        store: LibraryRegistryStore,
        activeOperations: [ActivityOperation],
        closeDatabase: () throws -> Void,
        pendingOpen: LibraryLaunchCoordinator.PendingOpenStore,
        relaunch: () -> Void,
        pathMigrationsDirectory: URL = OrganizedPathMigrationService.defaultArtifactsDirectory(),
        fileManager: FileManager = .default
    ) -> Outcome {
        if let problem = problem(newName: newName, currentName: currentName, package: package, fileManager: fileManager) {
            return .refused(problem)
        }
        let running = RunningWorkSummary(operations: activeOperations)
        if !running.isEmpty {
            return .refused(.workRunning(refusal(running)))
        }
        do {
            try closeDatabase()
        } catch {
            // Review S4: the writer may already be closed — never "nothing changed, try again".
            AppLogger.shared.error("Closing the library for the rename failed: \(error)", source: "Library")
            pendingOpen.set(package.path)
            return .relaunchRequired
        }
        do {
            let renamed = try rename(package: package, to: newName, libraryId: libraryId, store: store,
                                     pathMigrationsDirectory: pathMigrationsDirectory, fileManager: fileManager)
            pendingOpen.set(renamed.path)
            relaunch()
            return .relaunching(renamed)
        } catch {
            AppLogger.shared.error("Renaming the library failed and was undone: \(error)", source: "Library")
            pendingOpen.set(package.path)
            return .relaunchRequired
        }
    }

    /// `MLM can’t rename the library while 1 download is running. …` + one line per operation.
    static func refusal(_ summary: RunningWorkSummary) -> String {
        var text = "MLM can’t rename the library while \(summary.runningPhrase) running. Renaming relaunches MLM — let the work finish or cancel it in Activity first."
        for line in summary.lines { text += "\n• " + line }
        if summary.moreCount > 0 { text += "\n• and \(summary.moreCount.formatted(.number)) more" }
        return text
    }
}
