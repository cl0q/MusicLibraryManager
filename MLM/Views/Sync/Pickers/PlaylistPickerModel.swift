import Foundation

/// Pure selection/filter model behind PlaylistPickerSheet.
///
/// Included playlists stay visible in the row list, are marked `isIncluded`,
/// and cannot be toggled into/out of the user's pending selection.
struct PlaylistPickerModel {
    struct Row: Identifiable, Equatable {
        let playlist: Playlist
        let isIncluded: Bool
        let isSelected: Bool
        var id: Int64 { playlist.id ?? -1 }
    }

    private let allPlaylists: [Playlist]
    private let includedIDs: Set<Int64>

    var searchQuery: String = ""
    private(set) var selection: Set<Int64> = []

    init(allPlaylists: [Playlist], includedIDs: Set<Int64>) {
        self.allPlaylists = allPlaylists
        self.includedIDs = includedIDs
    }

    var rows: [Row] {
        let filtered: [Playlist]
        if searchQuery.isEmpty {
            filtered = allPlaylists
        } else {
            filtered = allPlaylists.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        return filtered.map { playlist in
            let pid = playlist.id ?? -1
            return Row(
                playlist: playlist,
                isIncluded: includedIDs.contains(pid),
                isSelected: selection.contains(pid)
            )
        }
    }

    func isIncluded(_ id: Int64) -> Bool {
        includedIDs.contains(id)
    }

    mutating func toggle(_ id: Int64) {
        guard !includedIDs.contains(id) else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    mutating func clearSelection() {
        selection.removeAll()
    }

    var commitIDs: [Int64] {
        selection.subtracting(includedIDs).sorted()
    }
}
