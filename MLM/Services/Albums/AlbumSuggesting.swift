import Foundation

/// Where Review ▸ Albums gets its suggestions (IMP-082). The shipped provider is
/// `TagAlbumSuggester` (the library's own tags and file names, no network); an online lookup
/// (MusicBrainz, §5 Q2) is a second implementation of this protocol — the lookup runner, the
/// repository and the view do not change.
protocol AlbumSuggesting: Sendable {
    /// The albums `track` may belong to, best match first or in any order (the runner ranks
    /// them). Empty = nothing found. Throws only for a failure of the provider itself.
    func suggest(for track: Track, context: AlbumSuggestionContext) async throws -> [AlbumSuggestion]
}

/// What a lookup run hands every `suggest` call: the library folder and the albums the
/// library already has per artist.
struct AlbumSuggestionContext: Sendable {
    /// The library folder (`organized_path` is relative to it).
    var libraryRoot: String?
    var index: ArtistAlbumIndex

    init(libraryRoot: String?, index: ArtistAlbumIndex = ArtistAlbumIndex()) {
        self.libraryRoot = libraryRoot
        self.index = index
    }
}

/// The albums every artist already has in the library (built once per lookup run):
/// per artist key (`AlbumKey.artistKey`) the albums with how many of the artist's tracks are on each.
struct ArtistAlbumIndex: Sendable {
    struct Entry: Sendable, Equatable {
        var title: String
        var albumArtist: String
        var year: Int?
        var tracks: Int
    }

    private(set) var byArtist: [String: [Entry]] = [:]

    init() {}

    /// Tallies `(artist, album artist, album, year)` of every track with a real album.
    init(tracks: [(artist: String, albumArtist: String, album: String, year: Int?)]) {
        struct Tally {
            var titles: [String: Int] = [:]
            var artists: [String: Int] = [:]
            var years: [Int: Int] = [:]
            var tracks = 0
        }
        var tallies: [String: [String: Tally]] = [:]
        for track in tracks where !AlbumKey.isNoAlbum(track.album) {
            let artist = AlbumKey.artistKey(track.artist)
            guard !artist.isEmpty else { continue }
            let album = AlbumKey.normalize(track.album)
            var tally = tallies[artist, default: [:]][album] ?? Tally()
            tally.titles[track.album.trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
            let albumArtist = track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !albumArtist.isEmpty { tally.artists[albumArtist, default: 0] += 1 }
            if let year = track.year { tally.years[year, default: 0] += 1 }
            tally.tracks += 1
            tallies[artist, default: [:]][album] = tally
        }
        func most<K: Hashable & Comparable>(_ counts: [K: Int]) -> K? {
            counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        for (artist, albums) in tallies {
            byArtist[artist] = albums.values.compactMap { tally in
                guard let title = most(tally.titles) else { return nil }
                return Entry(title: title, albumArtist: most(tally.artists) ?? "", year: most(tally.years), tracks: tally.tracks)
            }.sorted { ($0.tracks, $1.title) > ($1.tracks, $0.title) }
        }
    }

    func albums(of artist: String) -> [Entry] {
        byArtist[AlbumKey.artistKey(artist)] ?? []
    }
}

/// The provider that ships (IMP-082): three kinds of evidence, all from names and tags the
/// library already has — nothing is read from a file and nothing leaves the Mac.
///
/// - **Library tags** — albums other tracks by the same artist already have:
///   match = `50 + 45 × share`, share = the album's tracks of the artist ÷ the artist's tracks
///   with any album, at most 95.
/// - **Folder name** — the file's folder inside the library folder: `Artist/Album/` (match 90
///   when the grandparent folder is the track's artist) or `Album/` (80).
/// - **File name** — `Artist - Album - nn Title` (85), or `nn - Title` with the folder as the
///   album (75); `nn` is the track number.
///
/// Candidates for the same album are merged (the best match and source win; a track number or
/// year found by any of them is kept). The track number is a suggestion for the join only — it
/// is never written to a file (IMP-030).
struct TagAlbumSuggester: AlbumSuggesting {
    static let libraryTags = "Library tags"
    static let folderName = "Folder name"
    static let fileName = "File name"

    init() {}

    func suggest(for track: Track, context: AlbumSuggestionContext) async throws -> [AlbumSuggestion] {
        var candidates: [AlbumSuggestion] = []
        candidates += Self.fromLibraryTags(track: track, index: context.index)
        let location = Self.location(of: track, libraryRoot: context.libraryRoot)
        let number = location.flatMap { Self.leadingNumber(of: $0.stem) }
        if let location {
            candidates += Self.fromFolder(track: track, location: location, number: number?.value)
            candidates += Self.fromFileName(track: track, location: location, number: number)
        }
        return Self.merged(candidates, artist: track.artist).sorted { $0.match > $1.match }
    }

    // MARK: Library tags

    static func fromLibraryTags(track: Track, index: ArtistAlbumIndex) -> [AlbumSuggestion] {
        let entries = index.albums(of: track.artist)
        let withAlbum = entries.reduce(0) { $0 + $1.tracks }
        guard withAlbum > 0 else { return [] }
        return entries.map { entry in
            let share = Double(entry.tracks) / Double(withAlbum)
            return AlbumSuggestion(albumTitle: entry.title, albumArtist: entry.albumArtist, year: entry.year, trackNumber: nil,
                                   disc: nil, source: libraryTags, match: min(95, 50 + 45 * share))
        }
    }

    // MARK: Folder and file name

    /// Where a track's file sits in the library folder.
    struct Location: Equatable, Sendable {
        /// Folder names below the library folder, outermost first (empty = the file is in the library folder itself).
        var folders: [String]
        /// The file name without extension.
        var stem: String
    }

    static func location(of track: Track, libraryRoot: String?) -> Location? {
        guard var path = track.organizedPath, !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            // An absolute path only counts inside the library folder.
            guard let root = libraryRoot, !root.isEmpty else { return nil }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return nil }
            path = String(path.dropFirst(prefix.count))
        }
        var parts = path.split(separator: "/").map(String.init)
        guard let file = parts.popLast(), !file.isEmpty else { return nil }
        let stem = (file as NSString).deletingPathExtension
        return Location(folders: parts, stem: stem.isEmpty ? file : stem)
    }

    /// The album a track's folder names, if it names one: not the artist's own folder, not a
    /// source or generic folder.
    static func folderAlbum(track: Track, location: Location) -> (title: String, underArtist: Bool)? {
        guard let folder = location.folders.last?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else { return nil }
        guard !AlbumKey.isNoAlbum(folder), !genericFolders.contains(folder.lowercased()) else { return nil }
        let artist = AlbumKey.artistKey(track.artist)
        let folderKey = AlbumKey.artistKey(folder)
        guard folderKey != artist, folderKey != AlbumKey.artistKey(track.albumArtist) else { return nil }
        let parent = location.folders.dropLast().last.map(AlbumKey.artistKey)
        return (folder, parent == artist && !artist.isEmpty)
    }

    private static let genericFolders: Set<String> = ["music", "downloads", "tracks", "songs", "library", "unsorted", "singles", "new"]

    static func fromFolder(track: Track, location: Location, number: Int?) -> [AlbumSuggestion] {
        guard let album = folderAlbum(track: track, location: location) else { return [] }
        return [AlbumSuggestion(albumTitle: album.title, albumArtist: "", year: nil, trackNumber: number, disc: nil,
                                source: folderName, match: album.underArtist ? 90 : 80)]
    }

    /// `03 - Title`, `03. Title`, `03 Title`, `3-Title`: the leading track number and what follows.
    static func leadingNumber(of stem: String) -> (value: Int, rest: String)? {
        let trimmed = stem.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber && $0.isASCII }
        guard (1...3).contains(digits.count), let value = Int(digits), value > 0 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let first = rest.first, first == " " || first == "." || first == "-" || first == "_" else { return nil }
        let title = rest.drop { " .-_".contains($0) }
        return title.isEmpty ? nil : (value, String(title))
    }

    static func fromFileName(track: Track, location: Location, number: (value: Int, rest: String)?) -> [AlbumSuggestion] {
        let segments = location.stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        let artist = AlbumKey.artistKey(track.artist)
        // `Artist - Album - nn Title`
        if segments.count >= 3, !artist.isEmpty, AlbumKey.artistKey(segments[0]) == artist,
           !segments[1].isEmpty, !AlbumKey.isNoAlbum(segments[1]) {
            let tail = segments[2...].joined(separator: " - ")
            return [AlbumSuggestion(albumTitle: segments[1], albumArtist: "", year: nil,
                                    trackNumber: leadingNumber(of: tail)?.value, disc: nil, source: fileName, match: 85)]
        }
        // `nn - Title` with the folder as the album.
        if let number, let album = folderAlbum(track: track, location: location) {
            return [AlbumSuggestion(albumTitle: album.title, albumArtist: "", year: nil, trackNumber: number.value, disc: nil,
                                    source: fileName, match: 75)]
        }
        return []
    }

    // MARK: Merge

    /// One suggestion per album: the best match (and its source) wins, a track number, year or
    /// album artist found by another candidate is kept.
    static func merged(_ candidates: [AlbumSuggestion], artist: String) -> [AlbumSuggestion] {
        var byKey: [String: AlbumSuggestion] = [:]
        var order: [String] = []
        for candidate in candidates {
            let title = candidate.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !AlbumKey.isNoAlbum(title) else { continue }
            let key = AlbumKey.normalize(title)
            guard var best = byKey[key] else {
                byKey[key] = candidate
                order.append(key)
                continue
            }
            var other = candidate
            if other.match > best.match { swap(&best, &other) }
            best.trackNumber = best.trackNumber ?? other.trackNumber
            best.year = best.year ?? other.year
            best.disc = best.disc ?? other.disc
            if best.albumArtist.isEmpty { best.albumArtist = other.albumArtist }
            byKey[key] = best
        }
        return order.compactMap { byKey[$0] }
    }
}
