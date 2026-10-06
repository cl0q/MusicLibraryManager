import Foundation
import Observation

/// The Read Playlist Changes from Device sheet (S-SYNC-DEVICEINGEST merged into
/// S-SYNC-INGESTPREVIEW, F-11): scan (an Activity operation with Cancel), one card per changed
/// playlist with per-entry checkboxes, Apply = one undoable merge. An error of one card stays on
/// that card; the other cards stay visible (inventory: an apply error used to hide them).
@MainActor
@Observable
final class DevicePlaylistChangesModel {
    enum Phase: Equatable {
        case scanning(done: Int, total: Int)
        case loaded
        case notConnected
        case failed(String)
    }

    let profile: SyncProfile
    private(set) var phase: Phase = .scanning(done: 0, total: 0)
    private(set) var cards: [DevicePlaylistCard] = []
    private(set) var unchangedCount = 0
    private(set) var unreadable: [String] = []
    var selections: [String: DevicePlaylistSelection] = [:]
    var selectedCardID: String?
    private(set) var errors: [String: String] = [:]
    private(set) var isApplying = false

    @ObservationIgnored private let service: DevicePlaylistChangeService?
    @ObservationIgnored private let isReachable: (String) -> Bool
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(profile: SyncProfile, service: DevicePlaylistChangeService?,
         isReachable: @escaping (String) -> Bool = { SyncDestination.isReachable($0) }) {
        self.profile = profile
        self.service = service
        self.isReachable = isReachable
    }

    var deviceName: String { SyncDestination.deviceName(for: profile.outputFolder) }

    // MARK: Scan

    func scan() {
        scanTask?.cancel()
        errors = [:]
        guard isReachable(profile.outputFolder) else {
            phase = .notConnected
            return
        }
        guard let service, let profileID = profile.id else {
            phase = .failed("The library isn’t open.")
            return
        }
        phase = .scanning(done: 0, total: 0)
        let profile = self.profile
        // Activity (W3-ACT): `Read playlist changes from “‹profile›”`, with Cancel. The reading
        // itself runs off the main actor (the service's methods are nonisolated).
        let job = ActivityCenter.shared.begin(
            .deviceScan, title: "Read playlist changes from “\(profile.name)”",
            subject: .syncProfile(profileID, name: profile.name), itemNoun: .playlist,
            controls: ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancelScan() } }),
            graceful: true)
        let task = Task { @MainActor [weak self] in
            do {
                let found = try await service.scan(profile: profile) { [weak self] done, total in
                    job.update(completed: done, total: total)
                    Task { @MainActor [weak self] in
                        if case .scanning = self?.phase { self?.phase = .scanning(done: done, total: total) }
                    }
                }
                job.finish(ActivityResult(counts: [ActivityCount(.done, found.cards.count,
                    found.cards.count == 1 ? "playlist changed on the device" : "playlists changed on the device")]))
                self?.show(found)
            } catch is CancellationError {
                job.cancelled()
            } catch {
                let name = SyncDestination.deviceName(for: profile.outputFolder)
                job.fail(cause: "Couldn’t read “\(name)”")
                self?.phase = .failed("Couldn’t read “\(name)” — the device stopped answering.")
            }
        }
        scanTask = task
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func show(_ found: (cards: [DevicePlaylistCard], unchanged: Int, unreadable: [String])) {
        cards = found.cards
        unchangedCount = found.unchanged
        unreadable = found.unreadable
        selections = Dictionary(found.cards.map { ($0.id, DevicePlaylistSelection(card: $0)) }, uniquingKeysWith: { a, _ in a })
        selectedCardID = found.cards.first?.id
        phase = .loaded
    }

    /// For tests and previews: the cards as if scanned.
    func load(cards: [DevicePlaylistCard], unchanged: Int = 0) {
        show((cards, unchanged, []))
    }

    // MARK: Choices

    func binding(for cardID: String) -> DevicePlaylistSelection? { selections[cardID] }

    func toggle(_ cardID: String, added trackID: Int64) {
        guard var selection = selections[cardID] else { return }
        if selection.added.contains(trackID) { selection.added.remove(trackID) } else { selection.added.insert(trackID) }
        selections[cardID] = selection
    }

    func toggle(_ cardID: String, removed trackID: Int64) {
        guard var selection = selections[cardID] else { return }
        if selection.removed.contains(trackID) { selection.removed.remove(trackID) } else { selection.removed.insert(trackID) }
        selections[cardID] = selection
    }

    func setInclude(_ cardID: String, _ include: Bool) {
        selections[cardID]?.include = include
    }

    func setUseDeviceOrder(_ cardID: String, _ use: Bool) {
        selections[cardID]?.useDeviceOrder = use
    }

    /// Changes to existing playlists and playlists to create, over the included cards.
    var counts: (changes: Int, creates: Int) {
        var changes = 0
        var creates = 0
        for card in cards {
            guard let selection = selections[card.id], selection.include else { continue }
            if card.isNew {
                if !selection.added.isEmpty { creates += 1 }
            } else {
                changes += selection.changeCount
            }
        }
        return (changes, creates)
    }

    /// `Apply 5 Changes and Create 1 Playlist` (UC-SHEET-03: verb + count).
    var applyTitle: String {
        let (changes, creates) = counts
        let changeText = "\(changes.formatted(.number)) \(changes == 1 ? "Change" : "Changes")"
        let createText = "Create \(creates.formatted(.number)) \(creates == 1 ? "Playlist" : "Playlists")"
        switch (changes > 0, creates > 0) {
        case (true, true): return "Apply \(changeText) and \(createText)"
        case (false, true): return createText
        default: return "Apply \(changeText)"
        }
    }

    var canApply: Bool {
        let (changes, creates) = counts
        return phase == .loaded && !isApplying && changes + creates > 0
    }

    /// `3 of 9 playlist files differ from MLM`.
    var headline: String {
        let total = cards.count + unchangedCount
        return "\(cards.count.formatted(.number)) of \(total.formatted(.number)) playlist \(total == 1 ? "file differs" : "files differ") from MLM"
    }

    // MARK: Apply

    /// Applies the included cards as one undo step. Returns `true` when nothing is left to show
    /// (the sheet closes); cards that failed stay with their error.
    func apply(edits: ShellEdits) async -> Bool {
        guard let service, canApply else { return false }
        isApplying = true
        defer { isApplying = false }
        let items = cards.compactMap { card in selections[card.id].map { (card: card, selection: $0) } }
            .filter { $0.selection.include }
        let outcome = await edits.applyDeviceChanges(items, service: service, profileName: profile.name)
        errors = outcome.errors
        cards.removeAll { outcome.applied.contains($0.id) }
        for id in outcome.applied { selections[id] = nil }
        if let selected = selectedCardID, !cards.contains(where: { $0.id == selected }) {
            selectedCardID = cards.first?.id
        }
        return cards.isEmpty || cards.allSatisfy { selections[$0.id]?.include == false }
    }
}
