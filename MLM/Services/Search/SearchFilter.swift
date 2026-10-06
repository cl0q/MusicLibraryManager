import Foundation

// MARK: - The filter a view applies (UC-SEARCH-01/04, DEC-017)

/// What the search field asks a view to show: the typed text (free words and typed filter
/// clauses) plus the tokens chosen from the suggestions. Kinds combine with AND, values of one
/// kind with OR; free words are AND-ed against the track's searchable text.
///
/// **Adopting in-place filtering in a view** (the one seam, W2-I):
/// 1. Give the place a `SearchPlaceKey` and a `SearchFilterCapability` (`SearchPlace`).
/// 2. Read `searchCoordinator.filter(for: key)` and apply it:
///    - tracks in memory: `filter.matches(track)`;
///    - tracks in SQL: `TrackSearchSQL.predicate(for: filter)`;
///    - names (playlists, folders, groups): `filter.matchesName(_:)` — text only.
/// Tokens a place can't apply are ignored there; the field says so (`ignoredTokens(for:)`).
struct SearchFilter: Equatable, Hashable, Sendable {
    /// The field's text.
    var text: String
    /// Tokens chosen from the suggestions (inside the field).
    var tokens: [SearchToken]

    init(text: String = "", tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    static let empty = SearchFilter()

    /// The text parsed into free words and typed clauses. A link is never searched as text
    /// (`search.html` V-SEARCH.N14).
    var parsed: ParsedSearchText {
        isLink ? ParsedSearchText() : SearchQueryParser.parse(text)
    }

    /// Chosen tokens plus understood typed clauses, without duplicates.
    var allTokens: [SearchToken] {
        SearchQueryParser.merged(tokens, parsed.tokens)
    }

    /// Free words (folded matching against the searchable text).
    var freeTerms: [String] { parsed.freeTerms }

    /// The text is a pasted link (it shows link suggestions and filters nothing).
    var isLink: Bool { LinkSuggestion.isLink(text) }

    /// Nothing to filter by.
    var isEmpty: Bool { freeTerms.isEmpty && allTokens.isEmpty }

    /// Anything typed or chosen at all (the field is in use), links included.
    var hasInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tokens.isEmpty
    }

    /// The filter a place with `capability` applies: text-only places drop the tokens.
    func applicable(to capability: SearchFilterCapability) -> SearchFilter {
        switch capability {
        case .tracks: return self
        case .names: return SearchFilter(text: parsed.freeText)
        case .none: return .empty
        }
    }

    /// Tokens that `capability` can't apply (the field says they are ignored there).
    func ignoredTokens(for capability: SearchFilterCapability) -> [SearchToken] {
        switch capability {
        case .tracks: []
        case .names, .none: allTokens
        }
    }

    /// The words the online sources are asked for: free words plus artist / album / genre
    /// values (year, BPM and `is:` don't exist there).
    var onlineQuery: String {
        let values = allTokens.compactMap { token -> String? in
            if case .text(let value, _) = token.value { return value }
            return nil
        }
        return (freeTerms + values).joined(separator: " ")
    }

    /// The query as one line for titles and recent searches: `overmono genre: Techno`.
    var displayText: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([typed] + tokens.map(\.displayText)).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: In-memory matching (playlists, Review, Discover; mirrors `TrackSearchSQL`)

    /// Whether `track` passes the filter. `isInAnyPlaylist` answers `is: in no playlist`
    /// (`nil` = unknown: that word then matches nothing).
    func matches(_ track: Track, isInAnyPlaylist: ((Track) -> Bool?)? = nil) -> Bool {
        let terms = freeTerms
        if !terms.isEmpty, !track.matches(searchQuery: terms.joined(separator: " ")) { return false }
        let grouped = Dictionary(grouping: allTokens, by: \.kind)
        for (_, tokens) in grouped {
            guard tokens.contains(where: { Self.matches(track, token: $0, isInAnyPlaylist: isInAnyPlaylist) }) else {
                return false
            }
        }
        return true
    }

    /// Text-only match for names (playlists, folders, review groups): every free word is
    /// contained, ignoring case and diacritics.
    func matchesName(_ name: String) -> Bool {
        let terms = freeTerms
        guard !terms.isEmpty else { return true }
        let folded = Self.fold(name)
        return terms.allSatisfy { folded.contains(Self.fold($0)) }
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func matches(_ track: Track, token: SearchToken, isInAnyPlaylist: ((Track) -> Bool?)?) -> Bool {
        switch (token.kind, token.value) {
        case (.artist, .text(let value, let exact)):
            return textMatches(track.artist, value, exact) || textMatches(track.albumArtist, value, exact)
        case (.album, .text(let value, let exact)):
            return textMatches(track.album, value, exact)
        case (.genre, .text(let value, let exact)):
            return textMatches(track.genre ?? "", value, exact)
        case (.year, .range(let range)):
            return track.year.map(range.contains) ?? false
        case (.bpm, .range(let range)):
            return track.bpm.map(range.contains) ?? false
        case (.availability, .word(let word)):
            return matches(track, word: word, isInAnyPlaylist: isInAnyPlaylist)
        default:
            return false
        }
    }

    private static func textMatches(_ field: String, _ value: String, _ exact: Bool) -> Bool {
        let lhs = fold(field.trimmingCharacters(in: .whitespaces))
        let rhs = fold(value.trimmingCharacters(in: .whitespaces))
        return exact ? lhs == rhs : lhs.contains(rhs)
    }

    private static func matches(_ track: Track, word: SearchAvailabilityWord, isInAnyPlaylist: ((Track) -> Bool?)?) -> Bool {
        switch word {
        case .local: return TrackAvailabilityScope.local.contains(track.availability())
        case .notDownloaded: return TrackAvailabilityScope.notDownloaded.contains(track.availability())
        case .downloadFailed: return TrackAvailabilityScope.downloadFailed.contains(track.availability())
        case .fileMissing: return TrackAvailabilityScope.fileMissing.contains(track.availability())
        case .noAlbum: return !TrackMetadataPresentation.isRealAlbum(track.album) && !track.noAlbum
        case .noGenre: return GenreName.key(track.genre) == nil
        case .notAnalysed: return track.energyBucket == nil
        case .inNoPlaylist: return isInAnyPlaylist?(track).map { !$0 } ?? false
        case .linkedToSoundCloud: return track.linkedSourceName == "soundcloud"
        case .linkedToSpotify: return track.linkedSourceName == "spotify"
        case .linkedToYouTube: return track.linkedSourceName == "youtube"
        }
    }
}

private extension Track {
    /// The source a track was imported from, read from its stored original path (in memory;
    /// SQL also follows `track_sources`).
    var linkedSourceName: String? {
        let path = originalPath.lowercased()
        if path.hasPrefix("soundcloud://") || path.contains("soundcloud.com") { return "soundcloud" }
        if path.hasPrefix("spotify:") || path.contains("spotify.com") { return "spotify" }
        if path.hasPrefix("youtube://") || path.contains("youtube.com") || path.contains("youtu.be") { return "youtube" }
        return nil
    }
}

// MARK: - Places and what they can filter

/// What a place can filter by.
enum SearchFilterCapability: Equatable, Sendable {
    /// Track lists: free words and every token (All Tracks in SQL, playlists in memory).
    case tracks
    /// Lists of named things (playlists grid, folders, review groups, recommendations): free
    /// words against the name; tokens are ignored there.
    case names
    /// Nothing to filter (placeholders, settings-like pages): the text waits for a wider scope.
    case none
}

/// The query belongs to the view (UC-SEARCH-06): every place keeps its own query for the
/// session. A pushed playlist and the same playlist in the sidebar share one key.
struct SearchPlaceKey: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    static let allTracks = SearchPlaceKey("allTracks")
    static let allPlaylists = SearchPlaceKey("allPlaylists")
    static let folders = SearchPlaceKey("folders")
    static let review = SearchPlaceKey("review")
    static let discover = SearchPlaceKey("discover")
    static func playlist(_ id: Int64) -> SearchPlaceKey { SearchPlaceKey("playlist.\(id)") }
    static let genres = SearchPlaceKey("genres")
    /// A genre page by its name (`DetailRoute.genre`).
    static func genre(_ name: String) -> SearchPlaceKey { SearchPlaceKey("genre.\(name)") }

    var description: String { rawValue }
}

/// The visible place as search sees it: its key, what it can filter and its name (for the
/// hint when tokens don't apply).
struct SearchPlace: Equatable, Sendable {
    let key: SearchPlaceKey
    let capability: SearchFilterCapability
    let name: String

    static let allTracks = SearchPlace(key: .allTracks, capability: .tracks, name: "All Tracks")

    @MainActor
    init(_ navigation: NavigationModel, names: PlaceNames = PlaceNames()) {
        let title = navigation.title(names: names)
        if let route = navigation.currentRoute {
            switch route {
            case .playlist(let id, _):
                self.init(key: .playlist(id), capability: .tracks, name: title)
            case .album(let id):
                self.init(key: SearchPlaceKey("album.\(id)"), capability: .none, name: title)
            case .genre(let name):
                // The genre's tracks, filtered in memory (W3-GEN).
                self.init(key: .genre(name), capability: .tracks, name: title)
            case .similar(let id):
                self.init(key: SearchPlaceKey("similar.\(id)"), capability: .none, name: title)
            }
            return
        }
        switch navigation.selection {
        case .allTracks: self.init(key: .allTracks, capability: .tracks, name: title)
        case .albums: self.init(key: SearchPlaceKey("albums"), capability: .none, name: title)
        // The genre list filters by name (W3-GEN).
        case .genres: self.init(key: .genres, capability: .names, name: title)
        // Folders filters folders by name and tracks by the track filter (W3-FOLD).
        case .folders: self.init(key: .folders, capability: .tracks, name: title)
        case .discover: self.init(key: .discover, capability: .names, name: title)
        case .review: self.init(key: .review, capability: .names, name: title)
        case .allPlaylists: self.init(key: .allPlaylists, capability: .names, name: title)
        case .playlist(let id): self.init(key: .playlist(id), capability: .tracks, name: title)
        case .syncProfile(let id): self.init(key: SearchPlaceKey("syncProfile.\(id)"), capability: .none, name: title)
        }
    }

    init(key: SearchPlaceKey, capability: SearchFilterCapability, name: String) {
        self.key = key
        self.capability = capability
        self.name = name
    }

    /// The filter words this place offers in the suggestions (none where tokens don't apply).
    var offeredKinds: [SearchTokenKind] {
        capability == .tracks ? SearchTokenKind.allCases : []
    }
}

/// The search scope bar (UC-SEARCH-02, V-SEARCH.E04): `This view` is the default each time
/// search starts and after Esc.
enum SearchScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case thisView
    case library
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisView: "This view"
        case .library: "Library"
        case .online: "Online"
        }
    }
}
