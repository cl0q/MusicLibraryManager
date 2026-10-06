import Foundation
import Testing
@testable import MLM

/// The Folders outline as pure functions (W3-FOLD, DEC-024): paths, where a track lies, the
/// SQL catalog's grouping, the rows the table shows, the filter in place, files not in the
/// library, the outline order of a folder's tracks, and what is remembered per library.
@Suite("Folders outline (W3-FOLD)")
struct FolderOutlineTests {
    static let root = "/Volumes/Lexxar/Music"

    static func track(_ id: Int64, _ title: String, organized: String?, original: String? = nil) -> Track {
        var track = Track(artist: "Artist \(id)", album: "Album", title: title, format: "flac",
                          originalPath: original ?? "soundcloud://\(id)")
        track.id = id
        track.organizedPath = organized
        track.duration = 200
        return track
    }

    static func catalog(_ tracks: [Track]) -> FolderCatalog {
        FolderCatalog.build(tracks.map { FolderCatalog.Row(id: $0.id!, organizedPath: $0.organizedPath, originalPath: $0.originalPath) },
                            libraryRoot: root)
    }

    static func rows(_ tracks: [Track]) -> [Int64: TrackRow] {
        Dictionary(uniqueKeysWithValues: TrackRowBuilder.build(tracks).map { ($0.id, $0) })
    }

    // MARK: Paths

    @Test func relativePathsStayInsideTheLibraryFolder() {
        #expect(FolderPath.normalize("/a//b/./c/") == "a/b/c")
        #expect(FolderPath.parent(of: "a/b") == "a")
        #expect(FolderPath.parent(of: "a") == "")
        #expect(FolderPath.parent(of: "") == nil)
        #expect(FolderPath.ancestors(of: "a/b/c") == ["", "a", "a/b"])
        #expect(FolderPath.isWithin("a/b", "a") && FolderPath.isWithin("a", "") && !FolderPath.isWithin("ab", "a"))
        #expect(FolderPath.relative("/Volumes/Lexxar/Music/2026/x.flac", libraryRoot: Self.root) == "2026/x.flac")
        #expect(FolderPath.relative("/Volumes/Lexxar/Music", libraryRoot: Self.root + "/") == "")
        #expect(FolderPath.relative("/Volumes/Lexxar/Musicals/x.flac", libraryRoot: Self.root) == nil)
        #expect(!FolderPath.isSafe("../Other") && !FolderPath.isSafe("/abs") && FolderPath.isSafe("a/b"))
    }

    @Test func hiddenAndTemporaryFilesNeverShow() {
        #expect(!FolderPath.isListable(".DS_Store"))
        #expect(!FolderPath.isListable(".Track.flac.mlm-copy-1234"))
        #expect(!FolderPath.isListable("Track.flac.mlm-partial"))
        #expect(FolderPath.isListable("Track.flac"))
    }

    // MARK: Placement (no disk)

    @Test func aTrackLiesWhereItsFileIs() {
        // Imported where it lies: the original path wins over the organiser's suggestion.
        #expect(FolderPlacement.relativeFilePath(organizedPath: "Artist/Album/T.flac",
                                                 originalPath: "/Volumes/Lexxar/Music/2026/Jam/T.flac",
                                                 libraryRoot: Self.root) == "2026/Jam/T.flac")
        // A download: the organized path.
        #expect(FolderPlacement.relativeFilePath(organizedPath: "Downloads (SoundCloud)/T.m4a",
                                                 originalPath: "soundcloud://1", libraryRoot: Self.root) == "Downloads (SoundCloud)/T.m4a")
        // Absolute inside / outside the library folder; not downloaded.
        #expect(FolderPlacement.relativeFilePath(organizedPath: "/Volumes/Lexxar/Music/Sets/S.mp3",
                                                 originalPath: "x", libraryRoot: Self.root) == "Sets/S.mp3")
        #expect(FolderPlacement.relativeFilePath(organizedPath: "/Volumes/Other/S.mp3", originalPath: "x", libraryRoot: Self.root) == nil)
        #expect(FolderPlacement.relativeFilePath(organizedPath: nil, originalPath: "/Volumes/Lexxar/Music/a.mp3", libraryRoot: Self.root) == nil)
        #expect(FolderPlacement.relativeFilePath(organizedPath: "../escape.mp3", originalPath: "x", libraryRoot: Self.root) == nil)
    }

    // MARK: Catalog (counts from the database)

    @Test func theCatalogCountsTracksPerFolderIncludingSubfolders() {
        let catalog = Self.catalog([
            Self.track(1, "A", organized: "2026/Bandcamp/a.flac"),
            Self.track(2, "B", organized: "2026/Bandcamp/b.flac"),
            Self.track(3, "C", organized: "2026/c.flac"),
            Self.track(4, "D", organized: "root.flac"),
            Self.track(5, "E", organized: nil),
        ])
        #expect(catalog.trackCount(under: "") == 4)
        #expect(catalog.trackCount(under: "2026") == 3)
        #expect(catalog.trackCount(under: "2026/Bandcamp") == 2)
        #expect(catalog.folder("")?.childNames == ["2026"])
        #expect(catalog.folder("")?.directTrackIDs == [4], "root-level files are reachable (PP: unreachable before)")
        #expect(catalog.folder("2026")?.directTrackIDs == [3])
        #expect(catalog.folderCount(under: "") == 2)
        #expect(catalog.folderByTrackID[5] == nil, "not downloaded: in no folder")
        #expect(catalog.isKnownFile("2026/BANDCAMP/a.flac"), "matched like the disk: case-insensitive")
        #expect(!catalog.isKnownFile("2026/new.flac"))
    }

    @Test func knownFilesMatchDecomposedNames() {
        let catalog = Self.catalog([Self.track(1, "Jóga", organized: "Björk/Jóga.flac")])
        let decomposed = "Björk/Jóga.flac".decomposedStringWithCanonicalMapping
        #expect(catalog.isKnownFile(decomposed))
    }

    // MARK: The rows the table shows

    @Test func closedFoldersShowCountsAndKeepTheirTriangle() {
        let tracks = [Self.track(1, "A", organized: "2026/a.flac"), Self.track(2, "Z", organized: "z.flac")]
        let ids = FolderOutlineIDs()
        let outline = FolderOutline.build(FolderOutlineInput(catalog: Self.catalog(tracks), isOffline: true,
                                                             trackRows: Self.rows(tracks)), ids: ids)
        #expect(outline.rows.count == 2)
        let folder = try! #require(outline.rows.first?.folder)
        #expect(folder.name == "2026" && folder.trackCount == 1 && !folder.isExpanded)
        #expect(outline.rows[0].children?.count == 1, "one hidden child gives the closed folder its triangle")
        #expect(outline.rows[1].track?.title == "Z", "folders first, then tracks")
        #expect(outline.order == [ids.folder("2026"), 2], "a closed folder's child is not shown")
        #expect(outline.trackRows.map(\.position) == [1], "shown tracks are numbered in display order")
    }

    @Test func anOpenFolderShowsItsTracksSortedWithinTheFolder() {
        let tracks = [Self.track(1, "Beta", organized: "Sets/b.flac"), Self.track(2, "Alpha", organized: "Sets/a.flac"),
                      Self.track(3, "Gamma", organized: "Sets/Live/g.flac")]
        let ids = FolderOutlineIDs()
        var input = FolderOutlineInput(catalog: Self.catalog(tracks), isOffline: true, trackRows: Self.rows(tracks), expanded: ["Sets"])
        var outline = FolderOutline.build(input, ids: ids)
        let children = try! #require(outline.rows.first?.children)
        #expect(children.map { $0.folder?.name ?? $0.track?.title } == ["Live", "Alpha", "Beta"])
        #expect(outline.trackRows.map(\.title) == ["Alpha", "Beta"])
        input.sort = TrackSortOrder(column: .title, ascending: false)
        outline = FolderOutline.build(input, ids: ids)
        #expect(outline.rows.first?.children?.compactMap { $0.track?.title } == ["Beta", "Alpha"])
    }

    @Test func anOpenFolderWithoutLoadedTracksAsksForThem() {
        let tracks = [Self.track(1, "A", organized: "Sets/a.flac")]
        let outline = FolderOutline.build(FolderOutlineInput(catalog: Self.catalog(tracks), isOffline: true, expanded: ["Sets"]),
                                          ids: FolderOutlineIDs())
        #expect(outline.foldersMissingTracks == ["Sets"])
        if case .loading = outline.rows.first?.children?.first?.kind {} else { Issue.record("a Loading… row while the tracks load") }
    }

    @Test func filesOnDiskThatArentInTheLibraryShowDimmedInline() {
        let tracks = [Self.track(1, "A", organized: "Inbox/a.flac")]
        let listing = FolderListing(subfolders: ["Empty"], audioFiles: ["a.flac", "new.wav"])
        let input = FolderOutlineInput(catalog: Self.catalog(tracks),
                                       listings: ["": .listed(FolderListing(subfolders: ["Inbox"])), "Inbox": .listed(listing)],
                                       trackRows: Self.rows(tracks), expanded: ["Inbox"])
        let outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        let inbox = try! #require(outline.rows.first?.children)
        #expect(inbox.compactMap(\.folder).map(\.name) == ["Empty"], "a folder without library tracks, from disk")
        #expect(inbox.compactMap(\.file).map(\.name) == ["new.wav"], "a.flac is the library track")
        #expect(inbox.last?.file != nil, "folders, tracks, then files")
    }

    @Test func whileTheDriveIsAwayOnlyDatabaseRowsShow() {
        let tracks = [Self.track(1, "A", organized: "Inbox/a.flac")]
        let input = FolderOutlineInput(catalog: Self.catalog(tracks),
                                       listings: ["": .listed(FolderListing(subfolders: ["Inbox", "DiskOnly"]))],
                                       isOffline: true, trackRows: Self.rows(tracks))
        let outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        #expect(outline.rows.compactMap(\.folder).map(\.name) == ["Inbox"])
        #expect(outline.foldersToList.isEmpty, "nothing is read from a drive that isn't there")
    }

    @Test func anUnreadableFolderSaysSoOnItsRow() {
        let input = FolderOutlineInput(listings: ["": .listed(FolderListing(subfolders: ["Old"])),
                                                  "Old": .unreadable(reason: "permission denied")])
        let outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        #expect(outline.rows.first?.folder?.unreadableReason == "permission denied")
        #expect(outline.rows.first?.children == nil, "nothing to open")
    }

    @Test func managedFoldersAreLabelledAtTheTopOnly() {
        #expect(ManagedFolders.isManaged("Downloads (SoundCloud)"))
        #expect(!ManagedFolders.isManaged("2026/Downloads (SoundCloud)"))
        #expect(FolderRowText.facts(FolderRowInfo(path: "Downloads (YouTube)", name: "Downloads (YouTube)", trackCount: 2_306,
                                                  isManaged: true, notInLibraryCount: nil, unreadableReason: nil,
                                                  isScanning: false, isExpanded: false)) == "\(2_306.formatted(.number)) tracks · Managed by MLM")
        #expect(FolderRowText.notInLibrary(14) == "14 not in library")
    }

    @Test func theRootLimitsTheOutline() {
        let tracks = [Self.track(1, "A", organized: "2026/Sets/a.flac"), Self.track(2, "B", organized: "Other/b.flac")]
        let outline = FolderOutline.build(FolderOutlineInput(root: "2026", catalog: Self.catalog(tracks), isOffline: true,
                                                             trackRows: Self.rows(tracks)), ids: FolderOutlineIDs())
        #expect(outline.rows.compactMap(\.folder).map(\.path) == ["2026/Sets"])
    }

    @Test func idsAreStableAndNeverTrackIDs() {
        let ids = FolderOutlineIDs()
        #expect(ids.folder("a") == ids.folder("a"))
        #expect(ids.folder("a") != ids.file("a"))
        #expect(ids.folder("a") < 0 && ids.file("b") < 0)
    }

    // MARK: Filter in place

    @Test func theFilterKeepsMatchingTracksAndTheFoldersAboveThem() {
        let tracks = [Self.track(1, "Aphex", organized: "Albums/Aphex Twin/Syro/a.flac"),
                      Self.track(2, "Burial", organized: "Albums/Burial/b.flac"),
                      Self.track(3, "Dek", organized: "2026/Dekmantel/d.flac")]
        let catalog = Self.catalog(tracks)
        let match = FolderFilterMatch(trackIDs: [1])
        let input = FolderOutlineInput(catalog: catalog, isOffline: true, trackRows: Self.rows(tracks), filter: match)
        let outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        #expect(outline.rows.compactMap(\.folder).map(\.path) == ["Albums"], "2026 holds no match")
        #expect(outline.trackRows.map(\.id) == [1], "the filter opens the folders above a match")
        let albums = try! #require(outline.rows.first?.children)
        #expect(albums.compactMap(\.folder).map(\.name) == ["Aphex Twin"])
    }

    @Test func aFolderMatchedByNameShowsWithItsContentsWhenOpened() {
        let tracks = [Self.track(1, "One", organized: "2026/Dekmantel/1.flac"), Self.track(2, "Two", organized: "2026/Dekmantel/2.flac")]
        let match = FolderFilterMatch(nameMatchedFolders: ["2026/Dekmantel"])
        var input = FolderOutlineInput(catalog: Self.catalog(tracks), isOffline: true, trackRows: Self.rows(tracks), filter: match)
        var outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        let year = try! #require(outline.rows.first)
        #expect(year.folder?.isExpanded == true, "folders above a match open")
        #expect(year.children?.first?.folder?.isExpanded == false, "the matched folder stays as it was")
        input.expanded = ["2026/Dekmantel"]
        outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        #expect(outline.trackRows.map(\.title) == ["One", "Two"], "inside a matched folder everything shows")
    }

    @Test func aFolderTheFilterOpenedCanBeClosed() {
        let tracks = [Self.track(1, "A", organized: "Sets/a.flac")]
        let input = FolderOutlineInput(catalog: Self.catalog(tracks), isOffline: true, trackRows: Self.rows(tracks),
                                       collapsedByUser: ["Sets"], filter: FolderFilterMatch(trackIDs: [1]))
        let outline = FolderOutline.build(input, ids: FolderOutlineIDs())
        #expect(outline.rows.first?.folder?.isExpanded == false)
    }

    // MARK: Files not in the library (V-FOLD.E08)

    @Test func notInLibraryCountsCoverSubfolders() {
        let catalog = Self.catalog([Self.track(1, "A", organized: "2026/a.flac")])
        let listings: [String: FolderListingResult] = [
            "": .listed(FolderListing(subfolders: ["2026"], audioFiles: ["loose.mp3"])),
            "2026": .listed(FolderListing(subfolders: ["Jonas"], audioFiles: ["a.flac", "jam.wav"])),
            "2026/Jonas": .listed(FolderListing(audioFiles: ["01.flac", "02.flac"])),
        ]
        let files = FolderNotInLibrary.files(listings: listings, catalog: catalog)
        let counts = FolderNotInLibrary.recursiveCounts(files, folders: listings.keys)
        #expect(counts[""] == 4)
        #expect(counts["2026"] == 3)
        #expect(counts["2026/Jonas"] == 2)
        #expect(FolderNotInLibrary.files(under: "2026", in: files) == ["2026/jam.wav", "2026/Jonas/01.flac", "2026/Jonas/02.flac"])
        #expect(FolderNotInLibrary.headerText(count: 14, isLibraryFolder: false) == "14 files in this folder aren’t in the library")
        #expect(FolderNotInLibrary.headerText(count: 1, isLibraryFolder: true) == "1 file in the library folder isn’t in the library")
    }

    // MARK: A folder as its tracks (Add to Playlist ▸, drag)

    @Test func aFoldersTracksComeInOutlineOrder() {
        let tracks = [Self.track(1, "Zed", organized: "Sets/z.flac"), Self.track(2, "Ant", organized: "Sets/a.flac"),
                      Self.track(3, "Mid", organized: "Sets/B Side/m.flac"), Self.track(4, "Top", organized: "Sets/A Side/t.flac")]
        let ids = FolderTrackOrder.orderedTrackIDs(in: "Sets", catalog: Self.catalog(tracks), rows: Self.rows(tracks),
                                                   sort: TrackSortOrder(column: .title, ascending: true))
        #expect(ids == [4, 3, 2, 1], "subfolders by name first, then the folder's own tracks by title")
        #expect(FolderTrackOrder.merged([[1, 2], [2, 3]]) == [1, 2, 3])
    }

    // MARK: Remembered per library

    @Test func expansionAndRootAreRememberedPerLibraryAndFolder() throws {
        let suite = "mlm.tests.folders.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        FolderUIState(expanded: ["2026", "2026/Sets"], root: "2026").save(libraryID: "lib", libraryRoot: Self.root, defaults: defaults)
        let loaded = FolderUIState.load(libraryID: "lib", libraryRoot: Self.root + "/", defaults: defaults)
        #expect(loaded == FolderUIState(expanded: ["2026", "2026/Sets"], root: "2026"))
        #expect(FolderUIState.load(libraryID: "other", libraryRoot: Self.root, defaults: defaults) == FolderUIState())
        // Another library folder of the same library starts fresh; the old one is forgotten.
        FolderUIState.forgetOtherFolders(libraryID: "lib", keeping: "/Volumes/New/Music", defaults: defaults)
        #expect(FolderUIState.load(libraryID: "lib", libraryRoot: Self.root, defaults: defaults) == FolderUIState())
    }

    /// Ported from `FolderSelectionRegressionTests` (the old last-selection store).
    @Test func aStoredPathThatLeavesTheLibraryFolderIsDiscarded() throws {
        let suite = "mlm.tests.folders.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["expanded": ["../MLMTests", "ok", "/abs"], "root": "../MLMTests"],
                     forKey: FolderUIState.key(libraryID: "lib", libraryRoot: Self.root))
        let loaded = FolderUIState.load(libraryID: "lib", libraryRoot: Self.root, defaults: defaults)
        #expect(loaded.root == "")
        #expect(loaded.expanded == ["ok"])
    }
}
