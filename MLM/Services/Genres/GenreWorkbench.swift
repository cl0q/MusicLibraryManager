import Foundation
import Observation

/// The session state of the genre pages (V-GENRED): per genre the reference track, the
/// suggestions, the **staged** tracks and the suggestions hidden with `Not Now`.
///
/// Lives for the app session, outside every view: staged changes survive going back to the
/// list, switching places and closing the main window (the old Workshop lost them on `Genres`
/// and on closing Settings, ST-STUDIO-GENRE pain point) — only `Discard` or `Save` ends them.
/// Scoped to the open library: another library starts empty.
///
/// Suggestions are computed on demand as an Activity operation (`graceful`: visible only when it
/// takes longer than ~2 s, UC-JOB-01) and kept in memory — no table, no migration.
@MainActor
@Observable
final class GenreWorkbench {
    static let shared = GenreWorkbench()

    /// What the suggestion section shows.
    enum SuggestionState: Equatable, Sendable {
        /// No reference chosen yet (`Choose a reference track`).
        case noReference
        /// The reference has no similarity analysis (`“‹title›” hasn’t been analysed`).
        case notAnalysed
        case loading
        case ready
        /// The computation failed; the sentence says why.
        case failed(String)
    }

    struct Page: Equatable {
        var reference: Track?
        var suggestions: [GenreSuggestion] = []
        var state: SuggestionState = .noReference
        /// Staged tracks in the order they were staged (shown first, row state `Staged`).
        var staged: [Track] = []
        /// `Not Now` this session.
        var hidden: Set<Int64> = []
        /// The match of every track suggested this session (staged rows keep theirs).
        var matchByID: [Int64: Int] = [:]

        var stagedIDs: Set<Int64> { Set(staged.compactMap(\.id)) }
    }

    private(set) var pages: [String: Page] = [:]
    /// The suggestion section is expanded (V-GENRED.N04: collapsed by default, remembered).
    var isSuggestionsExpanded: Bool {
        didSet { defaults.set(isSuggestionsExpanded, forKey: Self.expandedKey) }
    }
    var options: GenreSuggestionOptions {
        didSet { options.save(defaults) }
    }

    @ObservationIgnored private var libraryID: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let activity: ActivityCenter?

    private static let expandedKey = "genres.suggestionsExpanded"

    init(defaults: UserDefaults = .standard, activity: ActivityCenter? = .shared) {
        self.defaults = defaults
        self.activity = activity
        self.isSuggestionsExpanded = defaults.bool(forKey: Self.expandedKey)
        self.options = GenreSuggestionOptions.load(defaults)
    }

    // MARK: Scope

    /// The open library; another one drops every page (staged edits belong to their library).
    func use(libraryID: String?) {
        guard libraryID != self.libraryID else { return }
        if self.libraryID != nil {
            tasks.values.forEach { $0.cancel() }
            tasks = [:]
            pages = [:]
        }
        self.libraryID = libraryID
    }

    func page(_ key: String) -> Page { pages[key] ?? Page() }

    /// Total staged tracks over every genre (`n changes not saved` in the list).
    func stagedCount(_ key: String) -> Int { pages[key]?.staged.count ?? 0 }

    // MARK: Staging (DEC-041: Save is one undo step)

    /// `Add to Genre` / a drop on the genre's table: tracks not in the genre are staged; returns
    /// how many were newly staged.
    @discardableResult
    func stage(_ tracks: [Track], genreKey: String) -> Int {
        var page = page(genreKey)
        var known = page.stagedIDs
        var added = 0
        for track in tracks {
            guard let id = track.id, GenreName.key(track.genre) != genreKey, known.insert(id).inserted else { continue }
            page.staged.append(track)
            added += 1
        }
        guard added > 0 else { return 0 }
        page.suggestions.removeAll { known.contains($0.id) }
        pages[genreKey] = page
        return added
    }

    /// `Remove` on a staged row: back to an ordinary suggestion (if it was one).
    func unstage(_ ids: Set<Int64>, genreKey: String) {
        guard var page = pages[genreKey] else { return }
        page.staged.removeAll { $0.id.map(ids.contains) ?? false }
        pages[genreKey] = page
    }

    /// `Discard`: every staged track of the genre is dropped; returns how many.
    @discardableResult
    func discard(genreKey: String) -> Int {
        guard var page = pages[genreKey] else { return 0 }
        let count = page.staged.count
        page.staged = []
        pages[genreKey] = page
        return count
    }

    /// After `Save`: the saved tracks leave the staging and the suggestions.
    func didSave(_ ids: Set<Int64>, genreKey: String) {
        guard var page = pages[genreKey] else { return }
        page.staged.removeAll { $0.id.map(ids.contains) ?? false }
        page.suggestions.removeAll { ids.contains($0.id) }
        pages[genreKey] = page
    }

    /// A genre was renamed or merged away: its staging moves to the new key (merged into what is
    /// staged there already).
    func move(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, let old = pages.removeValue(forKey: oldKey) else { return }
        tasks.removeValue(forKey: oldKey)?.cancel()
        var target = pages[newKey] ?? Page()
        let known = target.stagedIDs
        target.staged += old.staged.filter { !($0.id.map(known.contains) ?? true) && GenreName.key($0.genre) != newKey }
        target.hidden.formUnion(old.hidden)
        if target.reference == nil {
            target.reference = old.reference
            target.state = old.reference == nil ? .noReference : target.state
        }
        pages[newKey] = target
    }

    // MARK: Not Now (session only)

    func hide(_ ids: Set<Int64>, genreKey: String) {
        var page = page(genreKey)
        page.hidden.formUnion(ids)
        page.staged.removeAll { $0.id.map(ids.contains) ?? false }
        page.suggestions.removeAll { ids.contains($0.id) }
        pages[genreKey] = page
    }

    /// `Show Hidden (n)`: the hidden suggestions come back with the next computation.
    func unhideAll(genreKey: String) {
        guard var page = pages[genreKey], !page.hidden.isEmpty else { return }
        page.hidden = []
        pages[genreKey] = page
    }

    // MARK: Reference and suggestions

    func clearReference(genreKey: String) {
        tasks.removeValue(forKey: genreKey)?.cancel()
        var page = page(genreKey)
        page.reference = nil
        page.suggestions = []
        page.state = .noReference
        pages[genreKey] = page
    }

    /// Choose the reference and compute its suggestions (`Use as Reference for Suggestions`,
    /// `Use Selected Track`, `Pick a Typical Track`).
    func setReference(_ track: Track, genreKey: String, genreName: String,
                      repository: GenreRepository, source: GenreSimilaritySource) {
        var page = page(genreKey)
        page.reference = track
        page.suggestions = []
        pages[genreKey] = page
        recompute(genreKey: genreKey, genreName: genreName, repository: repository, source: source)
    }

    /// Compute the suggestions of the genre's reference again (options changed, `Show Hidden`,
    /// an analysis finished). Nothing without a reference.
    func recompute(genreKey: String, genreName: String, repository: GenreRepository, source: GenreSimilaritySource) {
        guard let reference = pages[genreKey]?.reference, let referenceID = reference.id else { return }
        tasks.removeValue(forKey: genreKey)?.cancel()
        var page = page(genreKey)
        page.state = .loading
        pages[genreKey] = page
        let options = self.options
        let job = activity?.begin(.trackAnalysis, title: "Find suggestions for “\(genreName)”",
                                  subject: .genres, itemNoun: .track, graceful: true, persists: false)
        tasks[genreKey] = Task { [weak self] in
            do {
                guard try await repository.hasSimilarityAnalysis(trackID: referenceID) else {
                    job?.discard()
                    self?.finish(genreKey, referenceID: referenceID, state: .notAnalysed, suggestions: [])
                    return
                }
                let candidates = try await source.similar(referenceID, GenreSuggestionRules.requestLimit(options),
                                                          options.match.temperature)
                try Task.checkCancellation()
                guard let self else { return }
                let current = self.page(genreKey)
                let picked = GenreSuggestionRules.pick(candidates, genreKey: genreKey, options: options,
                                                       hidden: current.hidden, staged: current.stagedIDs,
                                                       reference: referenceID)
                job?.finish(ActivityResult(counts: [ActivityCount(.done, picked.count, "suggested")]))
                self.finish(genreKey, referenceID: referenceID, state: .ready, suggestions: picked)
            } catch is CancellationError {
                job?.discard()
            } catch {
                AppLogger.shared.error("Genre suggestions failed: \(error)", source: "Genres")
                job?.fail(cause: "The library database didn’t answer")
                self?.finish(genreKey, referenceID: referenceID,
                             state: .failed("Couldn’t find suggestions — the library database didn’t answer."),
                             suggestions: [])
            }
        }
    }

    private func finish(_ genreKey: String, referenceID: Int64, state: SuggestionState, suggestions: [GenreSuggestion]) {
        // A newer reference won: drop this result.
        guard var page = pages[genreKey], page.reference?.id == referenceID else { return }
        page.state = state
        page.suggestions = suggestions
        for suggestion in suggestions { page.matchByID[suggestion.id] = suggestion.matchPercent }
        pages[genreKey] = page
        tasks[genreKey] = nil
    }

    /// Waits for the genre's running computation (tests).
    func waitForSuggestions(genreKey: String) async {
        await tasks[genreKey]?.value
    }
}
