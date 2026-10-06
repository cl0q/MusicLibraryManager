import Foundation
import GRDB
import Testing
@testable import MLM

/// How Genres plugs into the shared parts (W3-GEN): drop cells of the UC-DND matrix, the genre
/// container of the track table and its menu, the context columns, search, the menu bar, the
/// key map — and the old genre tools are gone, without German strings.
@Suite("Genres: drops, table, menus, search, removal of the old tools")
@MainActor
struct GenresPlaceTests {
    private let open = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)
    private let row = DropTarget.genreRow(key: "techno", name: "Techno")
    private let genreTable = DropTarget.genreTable(key: "techno", name: "Techno")

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func tracks(_ ids: [Int64], library: String? = "lib") -> DropContent {
        .tracks(TrackDragPayload(items: ids.map { TrackDragItem(trackId: $0, libraryId: library) }))
    }

    // MARK: Drops (D-SET-GW-TRACK-TO-GENRE, D-STUDIO-TRACK-TO-GENRE)

    @Test func aGenreRowTakesTracksOnlyAndSetsTheirGenre() {
        #expect(DropRules.accepts(.tracks, on: row, context: open))
        for kind in [DragKind.playlists, .files, .link, .imageData, .unknown] {
            #expect(!DropRules.accepts(kind, on: row, context: open), "\(kind) on a genre row: — (UC-DND matrix)")
        }
        #expect(DropRules.decide(tracks([3, 1, 3]), onto: row, context: open) == .setGenre([3, 1], genreName: "Techno"))
        #expect(DropRules.decide(tracks([1], library: "other"), onto: row, context: open) == .refuse(DropWords.otherLibrary))
        #expect(DropRules.decide(.playlists([PlaylistDragItem(playlistId: 1)]), onto: row, context: open) == .refuse(nil))
        #expect(DropRules.decide(.link(URL(string: "https://example.com")!), onto: row, context: open) == .refuse(nil))
        #expect(!DropRules.accepts(.tracks, on: row, context: DropContext(libraryID: nil, isLibraryOpen: false, offlineVolumeName: nil)))
    }

    @Test func theGenresTrackTableStagesDroppedTracks() {
        #expect(DropRules.accepts(.tracks, on: genreTable, context: open))
        #expect(!DropRules.accepts(.files, on: genreTable, context: open))
        #expect(DropRules.decide(tracks([5, 6]), onto: genreTable, context: open)
                == .stageForGenre([5, 6], genreKey: "techno", genreName: "Techno"))
        let audio = DropContent.files([DroppedFile(url: URL(fileURLWithPath: "/tmp/a.mp3"), kind: .audio)])
        #expect(DropRules.decide(audio, onto: genreTable, context: open) == .refuse(nil))
    }

    // MARK: The genre container (UC-KEY-17, CM-STUDIO-GENRETRACK)

    private func row(_ id: Int64) -> TrackRow {
        var track = Track(artist: "Artist", album: "", title: "Title \(id)", format: "m4a", originalPath: "/x/\(id).m4a")
        track.id = id
        track.organizedPath = "Artist/\(id).m4a"
        return TrackRowBuilder.build([track])[0]
    }

    @Test func aGenresTrackMenuRemovesFromTheGenreAndKeepsRemoveFromLibraryLast() {
        let container = TrackListContainer.genre(key: "techno", name: "Techno")
        let reference = TrackMenuExtra(id: "ref", title: "Use as Reference for Suggestions")
        let context = TrackMenuContext(container: container, canActivate: true, canRemoveFromContainer: true,
                                       canAddToSyncProfile: true, extras: TrackMenuExtras(info: [reference]))
        let menu = TrackMenuModel.make(subject: TrackMenuSubject(rows: [row(1)], live: .idle), context: context)
        let items = menu.items
        let removeIndex = try? #require(items.firstIndex(of: .removeFromContainer(title: "Remove from “Techno”")))
        #expect(removeIndex != nil)
        #expect(items.last == .removeFromLibrary(enabled: true))
        let info = try? #require(menu.sections.first { $0.contains(.getInfo) })
        #expect(info?.last == .extra(reference), "Use as Reference closes the Info group")
        #expect(TrackListContext.genre(key: "techno", name: "Techno").viewName == "“Techno”")
        #expect(TrackCommandState.removeTitle(container) == "Remove from “Techno”")
    }

    @Test func aSuggestionMenuPutsAddToGenreFirstAndNotNowBeforeRemoveFromLibrary() {
        let add = TrackMenuExtra(id: "add", title: "Add to “Techno”")
        let notNow = TrackMenuExtra(id: "notNow", title: "Not Now")
        let context = TrackMenuContext(container: .none, canActivate: true, canRemoveFromContainer: false,
                                       canAddToSyncProfile: true, extras: TrackMenuExtras(addTo: [add], remove: [notNow]))
        let menu = TrackMenuModel.make(subject: TrackMenuSubject(rows: [row(1), row(2)], live: .idle), context: context)
        let addTo = menu.sections.first { $0.contains(.addToPlaylist) }
        #expect(addTo?.first == .extra(add))
        let remove = menu.sections.last
        #expect(remove == [.extra(notNow), .removeFromLibrary(enabled: true)])
    }

    @Test func theGenreContainerSurvivesTheSavedQueue() throws {
        let origin = PlaybackOrigin(place: .genres, path: [.genre("Techno")], listKey: "genre",
                                    container: .genre(key: "techno", name: "Techno"))
        let text = try #require(SavedPlaybackOrigin.encode(origin))
        #expect(SavedPlaybackOrigin.decode(text) == origin)
        #expect(QueuePanelContent.name(of: origin) == "“Techno”")
    }

    // MARK: Context columns (Match, the verdicts)

    @Test func matchAndSuggestionColumnsOnlyWhereAskedFor() {
        #expect(!TrackColumnID.standardColumns.contains(.match))
        #expect(!TrackColumnID.standardColumns.contains(.suggestion))
        #expect(!TrackColumnID.hideableColumns.contains(.match))
        #expect(TrackListConfiguration(listContext: .allTracks, persistenceKey: "x").columns == TrackColumnID.standardColumns)
        #expect(TrackListConfiguration.playlist(id: 1, name: "P", activate: nil, remove: { _ in }, onInsert: nil).columns.first == .number)
        var context = TrackRowBuildContext.library
        context.matchPercents = [2: 93, 1: 70]
        var tracks: [Track] = []
        for id in [1, 2, 3] as [Int64] {
            var track = Track(artist: "A", album: "", title: "T\(id)", format: "m4a", originalPath: "/x/\(id)")
            track.id = id
            tracks.append(track)
        }
        let rows = TrackRowBuilder.build(tracks, context: context)
        #expect(rows.map(\.matchPercent) == [70, 93, nil])
        let best = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .match, ascending: false))
        #expect(best.map(\.id) == [2, 1, 3], "unknown match last")
    }

    // MARK: Search (UC-SEARCH-01, V-GENRES.N05)

    @Test func theListFiltersByNameAndAGenrePageByTracks() {
        let navigation = NavigationModel()
        navigation.select(.genres)
        #expect(SearchPlace(navigation).capability == .names)
        #expect(SearchPlace(navigation).key == .genres)
        navigation.push(.genre("Techno"))
        #expect(SearchPlace(navigation).capability == .tracks)
        #expect(SearchPlace(navigation).key == .genre("Techno"))
    }

    @Test func isNoGenreFindsTracksWithoutAGenre() async throws {
        #expect(SearchQueryParser.parse("is:no genre").tokens == [.availability(.noGenre)])
        var track = Track(artist: "A", album: "", title: "T", format: "m4a", originalPath: "/x")
        let filter = SearchFilter(tokens: [.availability(.noGenre)])
        #expect(filter.matches(track))
        track.genre = "  "
        #expect(filter.matches(track))
        track.genre = "Techno"
        #expect(!filter.matches(track))

        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            for (index, genre) in ([nil, "", "Techno"] as [String?]).enumerated() {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, genre, format, original_path, is_duplicate)
                    VALUES ('A', 'A', '', ?, ?, 'm4a', ?, 0)
                    """, arguments: ["T\(index)", genre, "/x/\(index)"])
            }
        }
        let (sql, arguments) = TrackSearchSQL.predicate(for: filter)
        let titles = try await db.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE \(sql) ORDER BY id", arguments: arguments)
        }
        #expect(titles == ["T0", "T1"])
    }

    // MARK: Menu bar and keys

    @Test func createMLTrainingSetIsWiredAndTheSaveKeyIsListed() throws {
        #expect(!MenuCommand.createMLTrainingSet.isPending)
        #expect(MenuCommand.createMLTrainingSet.title == "Create ML Training Set…")
        let file = try source("MLM/App/Commands/FileCommands.swift")
        #expect(file.contains("CommandButton(.createMLTrainingSet, enabled:"))
        #expect(file.contains("GenreRequests.shared.showsExportSheet = true"))
        let rows = KeyboardMap.visibleGroups.flatMap(\.rows)
        #expect(rows.contains { $0.keys == "⌘S" && $0.action.contains("staged") })
        // ⌘S is the staging bar's button (UC-KEY-31), never a menu item; Space / Return never are.
        #expect(!MenuCommand.allCases.contains { $0.shortcut == .cmd("s") })
        let section = try source("MLM/Views/Genres/GenreSuggestionsSection.swift")
        #expect(section.contains(".keyboardShortcut(\"s\", modifiers: .command)"))
        #expect(!section.contains(".keyboardShortcut(.space") && !section.contains(".keyboardShortcut(.return"))
    }

    @Test func genresAndTheGenrePageAreHosted() throws {
        let destination = try source("MLM/Views/Shell/DestinationView.swift")
        #expect(destination.contains("GenresView()"))
        #expect(destination.contains("GenreDetailView(name: name, onTrackActivated: onTrackActivated)"))
        #expect(!destination.contains("Genres aren’t available yet."))
        #expect(!destination.contains("Genre pages aren’t available yet."))
        let drops = try source("MLM/Views/DragDrop/DropTargetModifier.swift")
        #expect(drops.contains(".genreWindowRequests()"), "File ▸ Export opens the sheet wherever the user is")
    }

    // MARK: The old genre tools are gone (DEC-025, PP-INSPECTOR-26/27)

    @Test func theOldToolsAndTheirGermanStringsAreGone() throws {
        #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("MLM/Views/TrackDetail/GrooveStudioView.swift").path))
        let advanced = try source("MLM/Views/Settings/AdvancedSettingsView.swift")
        #expect(!advanced.contains("GrooveStudioView") && !advanced.contains("genresSection"))
        let enumerator = try #require(FileManager.default.enumerator(at: projectRoot.appendingPathComponent("MLM"),
                                                                      includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for german in ["Neuer kanonischer", "Genre-Name", "Per Audio", "z.B. Hip Hop"] {
                #expect(!text.contains(german), "\(url.lastPathComponent): \(german)")
            }
            #expect(!text.contains("GrooveStudioView"), "\(url.lastPathComponent)")
        }
        for path in ["GenresView", "GenreDetailView", "GenreSuggestionsSection", "GenreMergeSheet",
                     "CreateMLExportSheet", "GenreMenu", "GenreRequests"] {
            let code = try source("MLM/Views/Genres/\(path).swift")
            #expect(!code.contains("Genre Workshop") && !code.contains("Groove") && !code.contains("Temperature"), "\(path): UC-GLOSS-02")
            #expect(!code.contains("Color.mlm") && !code.contains("MLMFont") && !code.contains(".mlm"), "\(path): UC-COLOR-03")
            #expect(!code.contains("#available"), "\(path)")
            #expect(!code.contains("NSOpenPanel"), "\(path): UC-SHEET-24")
            #expect(!code.contains("Songs"), "\(path): tracks, never songs")
        }
    }
}
