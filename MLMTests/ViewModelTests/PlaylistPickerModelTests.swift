import Testing
import Foundation
import GRDB
@testable import MLM

/// Contract for the pure selection/filter model behind PlaylistPickerSheet.
///
/// The sync-profile playlist picker must show which playlists are ALREADY in
/// the selected sync profile: included playlists stay visible, are visibly
/// marked, and cannot be selected again.
@Suite("PlaylistPickerModelTests")
struct PlaylistPickerModelTests {

    private func makePlaylist(_ id: Int64, _ name: String) -> Playlist {
        var p = Playlist(id: nil, name: name, category: "regular",
                         isLiked: 0, isSmart: 0, isPinned: 0)
        p.id = id
        return p
    }

    private func makeModel() -> PlaylistPickerModel {
        PlaylistPickerModel(
            allPlaylists: [
                makePlaylist(1, "Liked from SoundCloud"),
                makePlaylist(2, "Local Likes"),
                makePlaylist(3, "Druhmy"),
                makePlaylist(4, "Gabber"),
            ],
            includedIDs: [2, 3]
        )
    }

    @Test func includedPlaylistsAreMarkedInRows() {
        let model = makeModel()
        let byID = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(byID[1]?.isIncluded == false)
        #expect(byID[2]?.isIncluded == true)
        #expect(byID[3]?.isIncluded == true)
        #expect(byID[4]?.isIncluded == false)
    }

    @Test func includedPlaylistsStayVisible() {
        let model = makeModel()
        // Included playlists must NOT be hidden — the point is to show them.
        #expect(model.rows.map(\.id).sorted() == [1, 2, 3, 4])
    }

    @Test func toggleIgnoresIncludedPlaylists() {
        var model = makeModel()
        model.toggle(2)
        model.toggle(3)
        #expect(model.selection.isEmpty)
        #expect(model.commitIDs.isEmpty)
    }

    @Test func toggleSelectsThenDeselects() {
        var model = makeModel()
        model.toggle(1)
        #expect(model.selection == [1])
        model.toggle(4)
        #expect(model.selection == [1, 4])
        model.toggle(1)
        #expect(model.selection == [4])
    }

    @Test func searchFiltersCaseInsensitivelyAndKeepsIncludedMarked() {
        var model = makeModel()
        model.searchQuery = "like"
        let ids = model.rows.map(\.id).sorted()
        #expect(ids == [1, 2])
        let byID = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(byID[1]?.isIncluded == false)
        #expect(byID[2]?.isIncluded == true)

        model.searchQuery = "DRUHMY"
        #expect(model.rows.map(\.id) == [3])
        #expect(model.rows.first?.isIncluded == true)
    }

    @Test func rowsCarrySelectionState() {
        var model = makeModel()
        model.toggle(4)
        let byID = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(byID[4]?.isSelected == true)
        #expect(byID[1]?.isSelected == false)
    }

    @Test func clearSelectionEmptiesCommitIDs() {
        var model = makeModel()
        model.toggle(1)
        model.toggle(4)
        #expect(model.commitIDs.sorted() == [1, 4])
        model.clearSelection()
        #expect(model.commitIDs.isEmpty)
        #expect(model.selection.isEmpty)
    }

    @Test func commitIDsNeverContainIncludedEvenAfterMixedToggles() {
        var model = makeModel()
        model.toggle(2)   // included -> ignored
        model.toggle(4)   // selectable
        model.toggle(3)   // included -> ignored
        #expect(model.commitIDs == [4])
    }
}
