import Testing
import Foundation

/// Source-scan tests verifying that track deletion is handled in-place
/// (no full SQL refetch) and that removed UI chrome / fonts are gone.
@Suite("DeleteInPlaceTests")
struct DeleteInPlaceTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // ViewTests
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - FIX 1: LibraryView delete handler uses in-place removal

    @Test
    func libraryView_deleteHandler_extractsRemovedIds() throws {
        let src = try readSource("MLM/Views/Library/LibraryView.swift")
        #expect(src.contains("removedIds"),
                "LibraryView must extract removedIds from the notification userInfo")
    }

    @Test
    func libraryView_deleteHandler_callsRemoveTracks() throws {
        let src = try readSource("MLM/Views/Library/LibraryView.swift")
        #expect(src.contains("removeTracks"),
                "LibraryView must call removeTracks(ids:) for in-place removal")
    }

    @Test
    func libraryView_deleteHandler_doesNotCallRefresh() throws {
        let src = try readSource("MLM/Views/Library/LibraryView.swift")
        // Find the libraryDidDeleteTracks handler block and ensure it does not call refresh
        let lines = src.components(separatedBy: "\n")
        var inDeleteHandler = false
        var braceDepth = 0
        for line in lines {
            if line.contains("libraryDidDeleteTracks") {
                inDeleteHandler = true
                braceDepth = 0
            }
            if inDeleteHandler {
                braceDepth += line.filter { $0 == "{" }.count
                braceDepth -= line.filter { $0 == "}" }.count
                if braceDepth <= 0 && line.contains("}") {
                    inDeleteHandler = false
                    continue
                }
                #expect(!line.contains("viewModel?.refresh()") && !line.contains("await viewModel?.refresh()"),
                        "LibraryView .libraryDidDeleteTracks handler must NOT call refresh()")
            }
        }
    }

    // MARK: - FIX 1: FoldersView delete handler uses in-place removal

    @Test
    func foldersView_deleteHandler_extractsRemovedIds() throws {
        let src = try readSource("MLM/Views/Folders/FoldersView.swift")
        #expect(src.contains("removedIds"),
                "FoldersView must extract removedIds from the notification userInfo")
    }

    @Test
    func foldersView_deleteHandler_callsRemoveTracks() throws {
        let src = try readSource("MLM/Views/Folders/FoldersView.swift")
        #expect(src.contains("removeTracks"),
                "FoldersView must call removeTracks(ids:) for in-place removal")
    }

    // MARK: - FIX 1: ViewModels expose removeTracks

    @Test
    func libraryViewModel_hasRemoveTracksMethod() throws {
        let src = try readSource("MLM/ViewModels/LibraryViewModel.swift")
        #expect(src.contains("func removeTracks(ids: Set<Int64>)"),
                "LibraryViewModel must expose a removeTracks(ids:) method")
    }

    @Test
    func folderViewModel_hasRemoveTracksMethod() throws {
        let src = try readSource("MLM/ViewModels/FolderViewModel.swift")
        #expect(src.contains("func removeTracks(ids: Set<Int64>)"),
                "FolderViewModel must expose a removeTracks(ids:) method")
    }

    // MARK: - FIX 2: Track count toolbar item removed

    @Test
    func libraryView_noTrackCountToolbarItem() throws {
        let src = try readSource("MLM/Views/Library/LibraryView.swift")
        #expect(!src.contains("tracks\")"),
                "LibraryView must not contain the 'N tracks' toolbar Text item")
    }

    // MARK: - FIX 3: PlaylistTable cells no longer use MLMFont.dataSmall

    @Test
    func playlistTable_timeCell_noDataSmallFont() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        // Find the PlaylistTableTimeCell struct and ensure it does not use MLMFont.dataSmall
        let lines = src.components(separatedBy: "\n")
        var inTimeCell = false
        var braceDepth = 0
        for line in lines {
            if line.contains("struct PlaylistTableTimeCell") {
                inTimeCell = true
                braceDepth = 0
            }
            if inTimeCell {
                braceDepth += line.filter { $0 == "{" }.count
                braceDepth -= line.filter { $0 == "}" }.count
                if braceDepth <= 0 && line.contains("}") {
                    break
                }
                #expect(!line.contains("MLMFont.dataSmall"),
                        "PlaylistTableTimeCell must not use MLMFont.dataSmall")
            }
        }
    }

    @Test
    func playlistTable_indexCell_noDataSmallFont() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        let lines = src.components(separatedBy: "\n")
        var inCell = false
        var braceDepth = 0
        for line in lines {
            if line.contains("struct PlaylistTableIndexCell") {
                inCell = true
                braceDepth = 0
            }
            if inCell {
                braceDepth += line.filter { $0 == "{" }.count
                braceDepth -= line.filter { $0 == "}" }.count
                if braceDepth <= 0 && line.contains("}") {
                    break
                }
                #expect(!line.contains("MLMFont.dataSmall"),
                        "PlaylistTableIndexCell must not use MLMFont.dataSmall")
            }
        }
    }

    @Test
    func playlistTable_yearCell_noDataSmallFont() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        let lines = src.components(separatedBy: "\n")
        var inCell = false
        var braceDepth = 0
        for line in lines {
            if line.contains("struct PlaylistTableYearCell") {
                inCell = true
                braceDepth = 0
            }
            if inCell {
                braceDepth += line.filter { $0 == "{" }.count
                braceDepth -= line.filter { $0 == "}" }.count
                if braceDepth <= 0 && line.contains("}") {
                    break
                }
                #expect(!line.contains("MLMFont.dataSmall"),
                        "PlaylistTableYearCell must not use MLMFont.dataSmall")
            }
        }
    }
}
