import Foundation

// MARK: - Reading folders on disk (off the main actor only)

/// What one directory holds, as the Folders outline uses it: the folders inside and the audio
/// files directly in it — hidden files, symbolic links and MLM's own temporary files
/// (`FolderPath.isListable`) left out. Names only, sorted like Finder.
struct FolderListing: Sendable, Equatable {
    var subfolders: [String] = []
    var audioFiles: [String] = []
}

/// One directory's listing, or why it couldn't be read (`Can’t read this folder`, V-FOLD.N09).
enum FolderListingResult: Sendable, Equatable {
    case listed(FolderListing)
    case unreadable(reason: String)

    var listing: FolderListing? {
        if case .listed(let listing) = self { return listing }
        return nil
    }
}

/// Reads directories. Every function here blocks on the file system and must run off the main
/// actor (a sleeping disk can take seconds to answer) — callers use `Task.detached`.
enum FolderDiskReader {
    /// The direct listing of `url` (one level).
    static func list(_ url: URL) -> FolderListingResult {
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .unreadable(reason: plainReason(error))
        }
        var listing = FolderListing()
        for item in contents {
            let name = item.lastPathComponent
            guard FolderPath.isListable(name) else { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                listing.subfolders.append(name)
            } else if values?.isRegularFile == true, MetadataExtractor.isAudioFile(item) {
                listing.audioFiles.append(name)
            }
        }
        listing.subfolders.sort(by: FolderSort.nameAscending)
        listing.audioFiles.sort(by: FolderSort.nameAscending)
        return .listed(listing)
    }

    /// Every directory under `root` (itself included), keyed by its path relative to `root`.
    /// Stops early (returning what it has) when `isCancelled` says so.
    static func walk(_ root: URL, isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> [String: FolderListingResult] {
        var result: [String: FolderListingResult] = [:]
        var pending = [""]
        while let relative = pending.popLast() {
            if isCancelled() { break }
            let listed = list(FolderPath.url(relative, libraryRoot: root.path))
            result[relative] = listed
            if let listing = listed.listing {
                for name in listing.subfolders.reversed() {
                    pending.append(FolderPath.join(relative, name))
                }
            }
        }
        return result
    }

    /// `Permission denied` and the like, without error codes (UC-COPY-11).
    static func plainReason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return "permission denied"
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return "the folder isn’t there any more"
            default: break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            if underlying.code == Int(EACCES) || underlying.code == Int(EPERM) { return "permission denied" }
            if underlying.code == Int(ENOENT) { return "the folder isn’t there any more" }
        }
        return nsError.localizedDescription
    }
}

// MARK: - Folder names for the search field's Library results (W2-I)

struct DiskFolderNode: Identifiable, Hashable, Sendable {
    let id: String            // Full filesystem path, e.g. /Volumes/Lexxar/Music/00_Artists
    let name: String          // Last path component
    let children: [DiskFolderNode]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Folder-name search of the search field's `Library` scope (`LibraryFolderSearch`). Runs off
/// the main actor (actor isolation).
actor DiskFolderScanner {
    /// Folders under `rootURL` whose name contains `query`, at most `limit` (the Library results
    /// show five rows and a total).
    func searchDirectories(under rootURL: URL, query: String, limit: Int = 200) async throws -> [DiskFolderNode] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedQuery.isEmpty else { return [] }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [DiskFolderNode] = []
        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true && values?.isSymbolicLink != true else { continue }
            let folderName = item.lastPathComponent
            guard FolderPath.isListable(folderName) else { continue }
            if folderName.lowercased().contains(trimmedQuery) {
                matches.append(DiskFolderNode(id: item.path, name: folderName, children: []))
            }
            if matches.count >= limit { break }
        }
        return matches
    }
}
