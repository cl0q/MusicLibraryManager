import Foundation

// MARK: - DiskFolderNode

struct DiskFolderNode: Identifiable, Hashable, Sendable {
    let id: String            // Full filesystem path, e.g. /Volumes/Lexxar/Music/00_Artists
    let name: String          // Last path component
    let children: [DiskFolderNode]

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

    /// Scan `rootURL` and return the full directory tree (no files included).
    ///
    /// - Throws: FileManager errors if the root is inaccessible.
    func scan(rootURL: URL) async throws -> [DiskFolderNode] {
        let start = Date()
        let nodes = try buildTree(at: rootURL, depth: 0)
        let total = countNodes(nodes)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        AppLogger.shared.info("disk folder scan: \(total) dirs in \(ms)ms", source: "perf")
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

    // MARK: - Private

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
            // Skip symlinks to avoid potential infinite loops.
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
