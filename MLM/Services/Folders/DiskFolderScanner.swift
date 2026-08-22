import Foundation

// MARK: - DiskFolderNode

struct DiskFolderNode: Identifiable, Hashable, Sendable {
    let id: String            // Full filesystem path, e.g. /Volumes/Lexxar/Music/00_Artists
    let name: String          // Last path component
    let children: [DiskFolderNode]

    var childrenOptional: [DiskFolderNode]? {
        children.isEmpty ? nil : children
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - DiskFolderScanner

/// Single-pass filesystem scanner that builds a directory tree.
///
/// Runs entirely off the main thread (actor isolation). FileManager calls
/// are cheap for directory enumeration but must not block the UI.
actor DiskFolderScanner {

    private static let maxDepth = 8

    /// Scan `rootURL` and return the directory tree.
    ///
    /// - Parameter recursive: If true, scans recursively down to maxDepth. If false (default), scans only the first level lazily.
    /// - Throws: FileManager errors if the root is inaccessible.
    func scan(rootURL: URL, recursive: Bool = true) async throws -> [DiskFolderNode] {
        let start = Date()
        let nodes: [DiskFolderNode]
        if recursive {
            nodes = try buildTree(at: rootURL, depth: 0)
        } else {
            nodes = try await scanSubdirectories(at: rootURL)
        }
        let total = countNodes(nodes)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        AppLogger.shared.info("disk folder scan (recursive=\(recursive)): \(total) dirs in \(ms)ms", source: "perf")
        return nodes
    }

    /// List audio files directly inside `dirURL` (one level, no recursion).
    func filesInDirectory(_ dirURL: URL) async throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )
        return contents.filter { url in
            guard MetadataExtractor.isAudioFile(url) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        }
    }

    /// Scan direct subdirectories of a given URL (one level only) and add placeholders if subdirectories exist.
    func scanSubdirectories(at url: URL) async throws -> [DiskFolderNode] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: .skipsHiddenFiles
        )
        
        var nodes: [DiskFolderNode] = []
        for item in contents {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true && values.isSymbolicLink != true else { continue }
            
            // Check if this subdirectory has subdirectories of its own using ultra-fast check
            let hasSubs = hasSubdirectories(at: item)
            let children: [DiskFolderNode]
            if hasSubs {
                // Add placeholder child to trigger SwiftUI disclosure arrow and lazy loading
                children = [DiskFolderNode(id: item.path + "/__placeholder__", name: "", children: [])]
            } else {
                children = []
            }
            
            nodes.append(DiskFolderNode(id: item.path, name: item.lastPathComponent, children: children))
        }
        
        return nodes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Recursively search the filesystem under `rootURL` for directories matching the query.
    func searchDirectories(under rootURL: URL, query: String) async throws -> [DiskFolderNode] {
        let start = Date()
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
            if folderName.lowercased().contains(trimmedQuery) {
                // Match found!
                let hasSubs = hasSubdirectories(at: item)
                let children = hasSubs ? [DiskFolderNode(id: item.path + "/__placeholder__", name: "", children: [])] : []
                matches.append(DiskFolderNode(id: item.path, name: folderName, children: children))
            }
            
            // Safety limit to avoid locking up on massive directories
            if matches.count >= 200 {
                break
            }
        }
        
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        AppLogger.shared.info("disk folder search for '\(query)': found \(matches.count) in \(ms)ms", source: "perf")
        return matches
    }

    // MARK: - Private

    private func hasSubdirectories(at url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return false }
        
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                return true
            }
        }
        return false
    }

    private func buildTree(at url: URL, depth: Int) throws -> [DiskFolderNode] {
        guard depth < Self.maxDepth else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: .skipsHiddenFiles
        )

        var nodes: [DiskFolderNode] = []
        for item in contents {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true else { continue }
            if values.isSymbolicLink == true { continue }

            let children = (try? buildTree(at: item, depth: depth + 1)) ?? []
            let sorted = children.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            nodes.append(DiskFolderNode(id: item.path, name: item.lastPathComponent, children: sorted))
        }

        return nodes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func countNodes(_ nodes: [DiskFolderNode]) -> Int {
        nodes.reduce(nodes.count) { $0 + countNodes($1.children) }
    }
}
