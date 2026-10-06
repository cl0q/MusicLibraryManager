import Foundation
import Observation

// MARK: - Discover ▸ Reels (V-REELS, DEC-029, IMP-059…062)

/// One reel of the list.
struct ReelItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    var artist: String
    var title: String
    var state: ReelState
    var createdAt: Date
    var guesses: [ReelGuess]

    var fileName: String { url.lastPathComponent }

    /// The list's second line: `Fred again.. — Delilah` or `Not identified yet`.
    var guessLine: String {
        if !artist.isEmpty, !title.isEmpty { return "\(artist) — \(title)" }
        if !artist.isEmpty || !title.isEmpty { return artist.isEmpty ? title : artist }
        return "Not identified yet"
    }
}

/// How a fragment of text is used (CM-REELS-TEXTPILL).
enum ReelFragmentUse: Equatable, Sendable {
    case artist, title, artistAndTitle
}

/// The workbench of one reel: what the right side shows. Memory only, except the guesses and
/// the two fields, which are the reel's record.
struct ReelBench: Equatable {
    enum Stills: Equatable { case notRead, reading, read }
    enum Audio: Equatable {
        case idle
        case listening
        /// Shazam found something (a guess); when it listened.
        case found(Date)
        case notRecognised
        case offline
        case failed(String)
    }
    enum SearchPhase: Equatable {
        /// No artist or title yet (V-REELS.E19).
        case nothingToSearch
        case searching(query: String)
        case results(query: String, groups: [ReelSearchGroup])
        /// Every source answered with nothing (V-REELS.N07).
        case noMatches(query: String)
        /// This Mac is offline (V-REELS.N08).
        case offline
    }

    var artist = ""
    var title = ""
    /// `Filled from: Shazam` / `Typed by you`.
    var filledFrom: String?
    var usedGuessID: String?
    var guesses: [ReelGuess] = []
    var keyframes: [ReelKeyframe] = []
    var fragments: [String] = []
    var stills: Stills = .notRead
    var audio: Audio = .idle
    var search: SearchPhase = .nothingToSearch
    var downloads: [String: ReelResultDownload] = [:]
    var trackIDs: [String: Int64] = [:]
    var videoReachable = true
    var searchToken = UUID()

    var isIdentifying: Bool { stills == .reading || audio == .listening }
    var canSearch: Bool {
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasIdentified: Bool { stills == .read || audio != .idle }
}

/// A request to the workbench's player (Play Video, Play from Here).
struct ReelPlayRequest: Equatable {
    let token = UUID()
    let reelID: String
    let offset: TimeInterval?
}

@MainActor
@Observable
final class ReelsModel {
    struct Dependencies {
        var repository: ReelRepository
        var analyzer: any ReelAnalyzing
        var audio: any ReelAudioIdentifying
        var search: any ReelSearching
        var fetcher: any ReelFetching
        var downloader: any ReelResultDownloading
        var fetchFolder: URL = ReelFetchLocation.defaultFolder
        var files: any ReelFileManaging = LiveReelFiles()
        /// Add a track to a playlist (the Add to Playlist ▸ path, undoable, says it in the status bar).
        var addToPlaylist: @MainActor (_ trackID: Int64, _ playlistID: Int64) async -> Void = { _, _ in }
        /// `New Playlist…` from one track (named inline in the sidebar).
        var newPlaylist: @MainActor (_ trackID: Int64) async -> Void = { _ in }
        /// Discover recounts, the sidebar follows.
        var postChange: @MainActor () -> Void = {}
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        var now: @Sendable () -> Date = { Date() }
        var makeID: @Sendable () -> String = { UUID().uuidString }
    }

    // MARK: State

    private(set) var items: [ReelItem] = []
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// The selected reels. Selecting never starts work (V-REELS.E04).
    private(set) var selection: Set<String> = []
    /// The reel the workbench shows: the last one selected.
    private(set) var focusedID: String?
    private(set) var benches: [String: ReelBench] = [:]
    /// Set by `Delete Reel…`; the alert is attached to the view while it is non-nil.
    var pendingDeletion: [String]?
    private(set) var playRequest: ReelPlayRequest?
    var statusBar: StatusBarCenter?
    var undo: UndoCenter?

    let dependencies: Dependencies
    @ObservationIgnored private let memory: ReelsSelectionMemory
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private var identifyTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(dependencies: Dependencies, memory: ReelsSelectionMemory? = nil, center: ActivityCenter? = nil) {
        self.dependencies = dependencies
        self.memory = memory ?? .shared
        self.center = center ?? .shared
    }

    // MARK: Words

    /// Listed counts: `5 reels · 3 new`.
    var countLine: String {
        let fresh = items.filter { $0.state == .new }.count
        let total = items.count == 1 ? "1 reel" : "\(items.count.formatted(.number)) reels"
        return fresh > 0 ? "\(total) · \(fresh.formatted(.number)) new" : total
    }

    static func addedSentence(added: Int, alreadyListed: Int) -> String {
        var text = added == 1 ? "Added 1 reel" : "Added \(added.formatted(.number)) reels"
        if alreadyListed > 0 { text += " · \(alreadyListed.formatted(.number)) already listed" }
        return text
    }

    static let nothingAddedSentence = "Those videos are already listed"

    /// `Deleted 1 reel — video file moved to the Trash` / `… — video file kept`.
    static func deletedSentence(count: Int, trashed: Bool) -> String {
        let what = count == 1 ? "Deleted 1 reel" : "Deleted \(count.formatted(.number)) reels"
        let files = count == 1 ? "video file" : "video files"
        return "\(what) — \(files) \(trashed ? "moved to the Trash" : "kept")"
    }

    static func deleteFailedSentence(fileName: String, cause: String) -> String {
        "Couldn’t delete “\(fileName)” — \(cause)"
    }

    /// The alert's title (`A-REELS-DELETE`).
    static func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete 1 reel?" : "Delete \(count.formatted(.number)) reels?"
    }

    /// `Also move the video file to the Trash` (plural when several).
    static func trashToggleTitle(count: Int) -> String {
        count == 1 ? "Also move the video file to the Trash" : "Also move the \(count.formatted(.number)) video files to the Trash"
    }

    /// The alert's message (UC UC-COPY: `Tracks you downloaded from it stay in the library.`, §23 C24).
    static let deleteMessage = "It is removed from this list. Tracks you downloaded from it stay in the library."

    // MARK: Derived

    var isEmpty: Bool { isLoaded && loadError == nil && items.isEmpty }
    var focusedItem: ReelItem? { focusedID.flatMap(item(for:)) }
    var focusedBench: ReelBench? { focusedID.flatMap { benches[$0] } }

    func item(for id: String) -> ReelItem? { items.first { $0.id == id } }

    private func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }

    /// Reels that still wait for a verdict (everything but Done) — what Discover counts.
    var notDoneCount: Int { items.filter { $0.state != .done }.count }

    // MARK: Loading

    func load() async {
        do {
            let records = try await dependencies.repository.fetchAll()
            items = records.map(Self.item(from:))
            loadError = nil
            isLoaded = true
            for item in items where benches[item.id] == nil { benches[item.id] = makeBench(for: item) }
            for id in benches.keys where self.item(for: id) == nil { benches[id] = nil }
            // The remembered reel, else the first: the right side is never a dead placeholder (E03/E05).
            let wanted = selection.isEmpty ? memory.reelID : focusedID
            let chosen = wanted.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items.first?.id
            setSelection(chosen.map { [$0] } ?? [], focus: chosen)
        } catch {
            AppLogger.shared.error("Loading reels failed: \(error.localizedDescription)", source: "Reels")
            loadError = error.localizedDescription
            isLoaded = true
        }
    }

    private static func item(from record: ImportedReelRecord) -> ReelItem {
        ReelItem(id: record.id, url: URL(fileURLWithPath: record.filePath), artist: record.artist, title: record.title,
                 state: record.state, createdAt: record.createdAt, guesses: ReelGuesses.decode(record.guessesJSON))
    }

    private func makeBench(for item: ReelItem) -> ReelBench {
        var bench = ReelBench()
        bench.artist = item.artist
        bench.title = item.title
        bench.guesses = item.guesses.isEmpty ? (ReelGuesses.fileNameGuess(item.fileName).map { [$0] } ?? []) : item.guesses
        bench.videoReachable = dependencies.files.fileExists(atPath: item.url.path)
        if let used = bench.guesses.first(where: { $0.artist == item.artist && $0.title == item.title }) {
            bench.usedGuessID = used.id
            bench.filledFrom = used.source.word
        }
        return bench
    }

    // MARK: Selection

    /// The list's selection changed. The reel the workbench shows is the newest selected one;
    /// the one before it saves its fields first (V-REELS.E09).
    func setSelection(_ ids: Set<String>, focus preferred: String? = nil) {
        let valid = ids.filter { id in items.contains { $0.id == id } }
        let previous = focusedID
        let added = valid.subtracting(selection)
        selection = valid
        let newFocus: String?
        if let preferred, valid.contains(preferred) {
            newFocus = preferred
        } else if added.count == 1, let one = added.first {
            newFocus = one
        } else if let previous, valid.contains(previous) {
            newFocus = previous
        } else {
            newFocus = items.first { valid.contains($0.id) }?.id
        }
        if let previous, previous != newFocus { queueCommit(of: previous) }
        focusedID = newFocus
        memory.reelID = newFocus
        if let newFocus, benches[newFocus] != nil {
            benches[newFocus]?.videoReachable = item(for: newFocus).map { dependencies.files.fileExists(atPath: $0.url.path) } ?? false
        }
    }

    // MARK: Fields (V-REELS.E09, K-REELS-RETURN)

    func setArtist(_ text: String) {
        guard let id = focusedID else { return }
        benches[id]?.artist = text
        benches[id]?.filledFrom = "Typed by you"
        benches[id]?.usedGuessID = nil
    }

    func setTitle(_ text: String) {
        guard let id = focusedID else { return }
        benches[id]?.title = text
        benches[id]?.filledFrom = "Typed by you"
        benches[id]?.usedGuessID = nil
    }

    /// The field lost focus: save what was typed (not on every keystroke).
    func commitFields() async {
        guard let id = focusedID else { return }
        queueCommit(of: id)
        await settle()
    }

    /// Waits for the saves started so far.
    func settle() async {
        await lastWrite?.value
    }

    private func queueCommit(of id: String) {
        guard let bench = benches[id], let item = item(for: id),
              bench.artist != item.artist || bench.title != item.title else { return }
        enqueueWrite { [self] in await persistFields(id: id, artist: bench.artist, title: bench.title) }
    }

    private func enqueueWrite(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastWrite
        lastWrite = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Writes artist and title; the state follows (Done stays Done unless both are cleared).
    private func persistFields(id: String, artist: String, title: String) async {
        do {
            let state = try await dependencies.repository.setFields(id: id, artist: artist, title: title, at: dependencies.now())
            guard let state, let at = index(of: id) else { return }
            items[at].artist = artist
            items[at].title = title
            items[at].state = state
            dependencies.postChange()
        } catch {
            AppLogger.shared.error("Saving reel fields failed: \(error.localizedDescription)", source: "Reels")
            statusBar?.post("Couldn’t save the artist and title — \(error.localizedDescription)",
                            actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
        }
    }

    // MARK: Use a guess / a fragment (IMP-061)

    private struct Fields: Equatable, Sendable {
        var artist: String
        var title: String
        var filledFrom: String?
        var usedGuessID: String?
    }

    private func fields(of id: String) -> Fields? {
        benches[id].map { Fields(artist: $0.artist, title: $0.title, filledFrom: $0.filledFrom, usedGuessID: $0.usedGuessID) }
    }

    private func apply(_ fields: Fields, to id: String) async {
        benches[id]?.artist = fields.artist
        benches[id]?.title = fields.title
        benches[id]?.filledFrom = fields.filledFrom
        benches[id]?.usedGuessID = fields.usedGuessID
        await settle()
        enqueueWrite { [self] in await persistFields(id: id, artist: fields.artist, title: fields.title) }
        await settle()
    }

    /// Replace the fields as one undo step (UC-UNDO-08); returns whether anything changed.
    @discardableResult
    private func change(_ actionName: String, to new: Fields, reel id: String, message: String) async -> Bool {
        guard let before = fields(of: id), before != new else { return false }
        guard let undo else {
            await apply(new, to: id)
            return true
        }
        _ = try? await undo.perform(
            actionName, failure: "Couldn’t change the artist and title",
            do: { [weak self] () async throws -> Fields? in
                await self?.apply(new, to: id)
                return before
            },
            undo: { [weak self] (previous: Fields) async throws -> Fields in
                await self?.apply(previous, to: id)
                return new
            },
            redo: { [weak self] (_: Fields) async throws -> Fields in
                await self?.apply(new, to: id)
                return before
            },
            message: { _ in message })
        return true
    }

    /// `Use` on a guess: fills both fields and searches — one undo step. Typed text is only
    /// ever replaced by this explicit press (IMP-061).
    func use(_ guess: ReelGuess) async {
        guard let id = focusedID else { return }
        let new = Fields(artist: guess.artist, title: guess.title, filledFrom: guess.source.word, usedGuessID: guess.id)
        await change("Use Guess", to: new, reel: id,
                     message: "Using the guess from \(guess.source.word) — searching \(ReelSource.allCases.count) sources")
        await search()
    }

    /// A text fragment's menu (CM-REELS-TEXTPILL). `Use as “Artist – Title”` does nothing when
    /// the text can't be split — the menu item is disabled then.
    func use(fragment text: String, as use: ReelFragmentUse) async {
        guard let id = focusedID, let bench = benches[id] else { return }
        switch use {
        case .artist:
            let new = Fields(artist: text, title: bench.title, filledFrom: ReelGuessSource.text.word, usedGuessID: nil)
            await change("Use Text as Artist", to: new, reel: id, message: "Artist set from the text in the video")
        case .title:
            let new = Fields(artist: bench.artist, title: text, filledFrom: ReelGuessSource.text.word, usedGuessID: nil)
            await change("Use Text as Title", to: new, reel: id, message: "Title set from the text in the video")
        case .artistAndTitle:
            let parts = ArtistTitleSplit.split(text)
            guard !parts.artist.isEmpty, !parts.title.isEmpty else { return }
            let new = Fields(artist: parts.artist, title: parts.title, filledFrom: ReelGuessSource.text.word, usedGuessID: nil)
            await change("Use Text as Artist and Title", to: new, reel: id,
                         message: "Using the guess from \(ReelGuessSource.text.word) — searching \(ReelSource.allCases.count) sources")
            await search()
        }
    }

    // MARK: Identify (V-REELS.E13, E15; runs only when asked)

    /// `Identify` / `Identify Again`: the stills and their text, and the audio. Produces guesses;
    /// fills nothing.
    func identify(_ id: String) async {
        guard let item = item(for: id), identifyTasks[id] == nil else { return }
        benches[id]?.stills = .reading
        benches[id]?.audio = .listening
        benches[id]?.videoReachable = dependencies.files.fileExists(atPath: item.url.path)
        let dependencies = self.dependencies
        let url = item.url
        let task = Task { @MainActor [weak self] in
            async let analysis = dependencies.analyzer.analyze(url)
            async let audio = dependencies.audio.identify(url)
            let (read, heard) = await (analysis, audio)
            guard !Task.isCancelled else { return }
            self?.finishIdentify(id, analysis: read, audio: heard)
        }
        identifyTasks[id] = task
        await task.value
        await settle()
        identifyTasks[id] = nil
    }

    /// Only the audio (the Guesses section's own button).
    func identifyByAudio(_ id: String) async {
        guard let item = item(for: id), identifyTasks[id] == nil, benches[id]?.audio != .listening else { return }
        benches[id]?.audio = .listening
        let audio = dependencies.audio
        let url = item.url
        let task = Task { @MainActor [weak self] in
            let heard = await audio.identify(url)
            guard !Task.isCancelled else { return }
            self?.finishAudio(id, heard)
        }
        identifyTasks[id] = task
        await task.value
        await settle()
        identifyTasks[id] = nil
    }

    /// The Cancel next to `Listening…`.
    func cancelIdentify(_ id: String) {
        identifyTasks[id]?.cancel()
        identifyTasks[id] = nil
        if benches[id]?.stills == .reading { benches[id]?.stills = benches[id]?.keyframes.isEmpty == false ? .read : .notRead }
        if benches[id]?.audio == .listening { benches[id]?.audio = .idle }
    }

    private func finishIdentify(_ id: String, analysis: ReelAnalysis, audio: ReelAudioResult) {
        guard benches[id] != nil else { return }
        benches[id]?.keyframes = analysis.keyframes
        benches[id]?.fragments = analysis.fragments
        benches[id]?.stills = .read
        let text = ReelGuesses.merge(fileName: nil, shazam: nil, text: analysis.candidates)
        replaceGuesses(.text, with: text, in: id)
        finishAudio(id, audio)
    }

    private func finishAudio(_ id: String, _ result: ReelAudioResult) {
        guard benches[id] != nil else { return }
        switch result {
        case .match(let match):
            replaceGuesses(.shazam, with: ReelGuesses.merge(fileName: nil, shazam: match, text: []), in: id)
            benches[id]?.audio = .found(dependencies.now())
        case .noMatch: benches[id]?.audio = .notRecognised
        case .offline: benches[id]?.audio = .offline
        case .failed(let cause): benches[id]?.audio = .failed(cause)
        }
    }

    private func replaceGuesses(_ source: ReelGuessSource, with new: [ReelGuess], in id: String) {
        guard let bench = benches[id] else { return }
        let merged = ReelGuesses.replacing(source, with: new, in: bench.guesses)
        benches[id]?.guesses = merged
        if let at = index(of: id) { items[at].guesses = merged }
        let json = ReelGuesses.encode(merged)
        enqueueWrite { [self] in try? await dependencies.repository.setGuesses(id: id, json: json, at: dependencies.now()) }
    }

    // MARK: Search (V-REELS.E11, K-REELS-RETURN)

    func search() async {
        guard let id = focusedID else { return }
        await commitFields()
        guard let bench = benches[id], bench.canSearch else { return }
        let query = ReelSearch.query(artist: bench.artist, title: bench.title)
        let token = UUID()
        benches[id]?.searchToken = token
        benches[id]?.search = .searching(query: query)
        statusBar?.post(ReelSearch.searchingSentence(query))
        let outcome = await dependencies.search.search(artist: bench.artist, title: bench.title)
        guard benches[id]?.searchToken == token else { return }
        switch outcome {
        case .offline:
            benches[id]?.search = .offline
        case .groups(let groups):
            benches[id]?.search = outcome.hasMatches ? .results(query: query, groups: groups) : .noMatches(query: query)
        }
    }

    // MARK: Download, Add to Playlist (V-REELS.E20/E21, CM-REELS-ADDPL)

    func download(_ result: ReelSearchResult) async {
        _ = await start(result)
    }

    func addToPlaylist(_ result: ReelSearchResult, playlistID: Int64) async {
        guard let trackID = await start(result) else { return }
        await dependencies.addToPlaylist(trackID, playlistID)
    }

    func newPlaylist(from result: ReelSearchResult) async {
        guard let trackID = await start(result) else { return }
        await dependencies.newPlaylist(trackID)
    }

    /// Hands the result to the pipeline (the track has no album); the reel is Done from now on.
    private func start(_ result: ReelSearchResult) async -> Int64? {
        guard let id = focusedID, benches[id] != nil else { return nil }
        if let known = benches[id]?.trackIDs[result.id], let state = benches[id]?.downloads[result.id], !state.isFailed {
            return known
        }
        benches[id]?.downloads[result.id] = .queued
        switch await dependencies.downloader.start(result) {
        case .started(let trackID):
            benches[id]?.trackIDs[result.id] = trackID
            statusBar?.post(SearchDownloadService.startedMessage(result.title))
            await markDoneAutomatically(id)
            startPolling()
            return trackID
        case .alreadyInLibrary(let trackID):
            benches[id]?.trackIDs[result.id] = trackID
            benches[id]?.downloads[result.id] = .inLibrary
            statusBar?.post(SearchDownloadService.alreadyInLibraryMessage(result.title))
            await markDoneAutomatically(id)
            return trackID
        case .failed(let cause):
            benches[id]?.downloads[result.id] = .failed(cause)
            statusBar?.post("Couldn’t download “\(result.title)” — \(cause)",
                            actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
            return nil
        }
    }

    private func markDoneAutomatically(_ id: String) async {
        guard let at = index(of: id), items[at].state != .done else { return }
        do {
            try await dependencies.repository.setState(id: id, .done, at: dependencies.now())
            items[at].state = .done
            dependencies.postChange()
        } catch {
            AppLogger.shared.error("Marking a reel done failed: \(error.localizedDescription)", source: "Reels")
        }
    }

    /// Re-reads where the downloads stand (a download finished, or the poll's next beat).
    func refreshDownloads() async {
        for (reelID, bench) in benches {
            for (resultID, trackID) in bench.trackIDs where benches[reelID]?.downloads[resultID]?.isFinal != true {
                benches[reelID]?.downloads[resultID] = await dependencies.downloader.progress(of: trackID)
            }
        }
    }

    private var hasPendingDownloads: Bool {
        benches.values.contains { bench in bench.trackIDs.keys.contains { bench.downloads[$0]?.isFinal != true } }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.hasPendingDownloads {
                await self.dependencies.sleep(.seconds(1.5))
                if Task.isCancelled { break }
                await self.refreshDownloads()
            }
            self?.pollTask = nil
        }
    }

    /// `Retry` on a failed row.
    func retry(_ result: ReelSearchResult) async {
        guard let id = focusedID else { return }
        benches[id]?.downloads[result.id] = nil
        benches[id]?.trackIDs[result.id] = nil
        await download(result)
    }

    // MARK: Mark as Done (V-REELS.N04) — undoable

    func markDone(_ ids: Set<String>) async {
        let targets = items.filter { ids.contains($0.id) && $0.state != .done }
        guard !targets.isEmpty else { return }
        let before = targets.map { ($0.id, $0.state) }
        let name = targets.count == 1 ? "Mark as Done" : "Mark \(targets.count.formatted(.number)) Reels as Done"
        let message = targets.count == 1 ? "Marked as Done" : "Marked \(targets.count.formatted(.number)) reels as Done"
        let setAll: @MainActor ([(String, ReelState)]) async throws -> Void = { [weak self] states in
            guard let self else { return }
            for (id, state) in states {
                try await self.dependencies.repository.setState(id: id, state, at: self.dependencies.now())
                if let at = self.index(of: id) { self.items[at].state = state }
            }
            self.dependencies.postChange()
        }
        guard let undo else {
            try? await setAll(targets.map { ($0.id, ReelState.done) })
            return
        }
        _ = try? await undo.perform(
            name, failure: "Couldn’t mark as Done",
            do: { () async throws -> [ReelStateChange]? in
                try await setAll(before.map { ($0.0, ReelState.done) })
                return before.map { ReelStateChange(id: $0.0, state: $0.1) }
            },
            undo: { (previous: [ReelStateChange]) async throws -> [ReelStateChange] in
                try await setAll(previous.map { ($0.id, $0.state) })
                return previous
            },
            redo: { (previous: [ReelStateChange]) async throws -> [ReelStateChange] in
                try await setAll(previous.map { ($0.id, ReelState.done) })
                return previous
            },
            message: { _ in message })
    }

    // MARK: Delete Reel… (IMP-062, A-REELS-DELETE)

    func requestDelete(_ ids: Set<String>) {
        let existing = items.filter { ids.contains($0.id) }.map(\.id)
        pendingDeletion = existing.isEmpty ? nil : existing
    }

    /// The alert's `Delete`: the video goes to the Trash first when asked; a reel whose file
    /// can't be moved (or whose row can't be deleted) stays listed and is named in the status
    /// bar with the cause (A-REELS-DELETEERROR). Not undoable (UC-UNDO-03).
    func confirmDelete(moveFilesToTrash: Bool) async {
        guard let ids = pendingDeletion else { return }
        pendingDeletion = nil
        var deleted = 0
        var failures: [(String, String)] = []
        for id in ids {
            guard let item = item(for: id) else { continue }
            if moveFilesToTrash, dependencies.files.fileExists(atPath: item.url.path) {
                do { try dependencies.files.trash(item.url) } catch {
                    failures.append((item.fileName, Self.cause(error)))
                    continue
                }
            }
            do {
                try await dependencies.repository.delete(id: id)
                deleted += 1
                items.removeAll { $0.id == id }
                benches[id] = nil
                identifyTasks[id]?.cancel()
                identifyTasks[id] = nil
            } catch {
                failures.append((item.fileName, Self.cause(error)))
            }
        }
        if deleted > 0 {
            let remaining = selection.filter { id in items.contains { $0.id == id } }
            let focus = focusedID.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items.first?.id
            setSelection(remaining.isEmpty ? Set(focus.map { [$0] } ?? []) : remaining, focus: focus)
            dependencies.postChange()
            statusBar?.post(Self.deletedSentence(count: deleted, trashed: moveFilesToTrash))
        }
        if let failure = failures.first {
            AppLogger.shared.error("Deleting reel “\(failure.0)” failed: \(failure.1)", source: "Reels")
            statusBar?.post(Self.deleteFailedSentence(fileName: failure.0, cause: failure.1),
                            actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
        }
    }

    private static func cause(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "the reason is in the log" : text
    }

    // MARK: Import and drops (V-REELS.E02, N01, N02)

    /// The open panel's choice and a Finder drop: videos and folders (subfolders included).
    /// Nothing is copied; reels stay where they are.
    func importURLs(_ urls: [URL]) async {
        let scan = await Task.detached { ReelImporter.scan(urls) }.value
        for folder in scan.emptyFolders { statusBar?.post(ReelImporter.noVideosSentence(folder)) }
        if !scan.refused.isEmpty, scan.videos.isEmpty, scan.emptyFolders.isEmpty {
            statusBar?.post(ReelImporter.notAVideoSentence(scan.refused))
            return
        }
        guard !scan.videos.isEmpty else { return }
        let existing = Set(items.map(\.url.path))
        let records = ReelImporter.records(for: scan.videos, excluding: existing, now: dependencies.now(), makeID: dependencies.makeID)
        let already = scan.videos.count - records.count
        guard !records.isEmpty else {
            statusBar?.post(Self.nothingAddedSentence)
            return
        }
        var saved: [ImportedReelRecord] = []
        for record in records {
            do {
                try await dependencies.repository.save(record)
                saved.append(record)
            } catch {
                AppLogger.shared.error("Saving a reel failed: \(error.localizedDescription)", source: "Reels")
            }
        }
        guard !saved.isEmpty else {
            statusBar?.post("Couldn’t add the videos — the library didn’t take them",
                            actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
            return
        }
        insert(saved)
        statusBar?.post(Self.addedSentence(added: saved.count, alreadyListed: already))
        dependencies.postChange()
    }

    private func insert(_ records: [ImportedReelRecord]) {
        let new = records.map(Self.item(from:))
        // Newest first, as the repository lists them.
        items = new + items
        for item in new { benches[item.id] = makeBench(for: item) }
        if focusedID == nil, let first = items.first { setSelection([first.id], focus: first.id) }
    }

    /// A Finder drop on the view (`DropRules` decided it): same as `Import…`.
    func addDropped(_ urls: [URL]) {
        Task { await importURLs(urls) }
    }

    /// A link dropped on the view.
    func addDroppedLink(_ url: URL) {
        guard let link = ReelLinkParser.parse(url.absoluteString) else {
            statusBar?.post(ReelLinkParser.refusal)
            return
        }
        addLink(link)
    }

    /// `Add Reel` in the sheet: a refusal for a link of another kind, else the fetch starts as
    /// an Activity operation (`Fetching reel…`) and the sheet closes.
    func addLink(text: String) -> String? {
        guard let link = ReelLinkParser.parse(text) else { return ReelLinkParser.refusal }
        addLink(link)
        return nil
    }

    @discardableResult
    func addLink(_ link: ReelLink) -> Task<Void, Never> {
        let job = center.begin(.reelsDownload, title: "Fetching reel…", subject: .reels, itemNoun: .item,
                               messageName: "Reel fetch", lane: nil)
        let dependencies = self.dependencies
        return Task { @MainActor [weak self] in
            do {
                let file = try await dependencies.fetcher.fetch(link, into: dependencies.fetchFolder)
                if let self, !self.items.contains(where: { $0.url.path == file.path }) {
                    // A fetched video arrives as New: its name is the site's id, not a song.
                    var records = ReelImporter.records(for: [file], excluding: [], now: dependencies.now(), makeID: dependencies.makeID)
                    for at in records.indices {
                        records[at].artist = ""
                        records[at].title = ""
                        records[at].state = .new
                        records[at].guessesJSON = nil
                    }
                    for record in records { try await dependencies.repository.save(record) }
                    self.insert(records)
                    dependencies.postChange()
                }
                job.finish(ActivityResult(counts: [ActivityCount(.done, 1, "fetched")]))
            } catch {
                let cause = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                job.fail(cause: cause)
                AppLogger.shared.error("Fetching a reel failed: \(cause)", source: "Reels")
            }
        }
    }

    // MARK: Playing the video

    func playVideo(_ id: String, from offset: TimeInterval? = nil) {
        if focusedID != id || selection != [id] { setSelection([id], focus: id) }
        playRequest = ReelPlayRequest(reelID: id, offset: offset)
    }
}

/// What `Mark as Done` changed, for Undo.
struct ReelStateChange: Equatable, Sendable {
    let id: String
    let state: ReelState
}

extension ReelResultDownload {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
