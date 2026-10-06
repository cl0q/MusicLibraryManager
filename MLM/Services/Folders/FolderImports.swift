import Foundation

// MARK: - Scan This Folder ⌘R and Import ‹n› Files (CM-FOLD-TREE.N06/N07, V-FOLD.E08)

/// The Folders place's imports — Activity operations through `ImportViewModel` (W3-ACT: progress,
/// Cancel after the current file, a result kept in Activity, start and end said in the status
/// bar). Both import **where the files are**: they already lie in the library folder.
@MainActor
enum FolderImports {
    /// `Scan “‹folder›”`: reads the folder (subfolders included), imports what isn't in the
    /// library, and posts `.libraryFilesDidChange` so the file check finds moved and deleted
    /// files too.
    static func scan(_ folder: URL, container: DependencyContainer = .shared) async {
        guard let importer = makeImporter(container) else { return }
        await importer.importFromDirectory(folder)
        postAfterInterruption(importer)
    }

    /// `Import ‹n› Files` / `Import File`: exactly these files (the outline's `Not in library`
    /// rows, or every such file of a folder).
    static func importFiles(_ files: [URL], container: DependencyContainer = .shared) async {
        guard !files.isEmpty, let importer = makeImporter(container) else { return }
        let title = files.count == 1
            ? "Import “\(files[0].lastPathComponent)”"
            : DropWords.importTitle(files: files.count, folderName: nil, playlist: nil)
        await importer.importFiles(files, title: title)
        postAfterInterruption(importer)
    }

    /// A finished import posted these itself; after a cancel or an error some files may be
    /// committed — post them as the old Folders import always did (W3-ACT S7).
    private static func postAfterInterruption(_ importer: ImportViewModel) {
        if importer.lastResult == nil || importer.lastResult?.cancelled == true {
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            NotificationCenter.default.post(name: .libraryFilesDidChange, object: nil)
        }
    }

    /// A throwaway importer: the import lane queues it behind a running import, and Activity's
    /// `Run Again` keeps it alive (W3-ACT S5).
    private static func makeImporter(_ container: DependencyContainer) -> ImportViewModel? {
        guard let service = container.importService, let config = container.configRepository else { return nil }
        return ImportViewModel(importService: service, configRepository: config, activity: .shared)
    }
}
