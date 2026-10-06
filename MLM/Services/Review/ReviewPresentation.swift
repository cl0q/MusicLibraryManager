import Foundation

// MARK: - Groups

/// A review unit made of queue rows. Scan results make one row per group; pair-only rows of
/// older databases stay readable (`legacy:‹id›`).
struct ReviewGroup: Identifiable {
    let key: String
    let items: [ReviewItem]

    var id: String { key }
    var primaryItem: ReviewItem { items[0] }
    var actionType: String { primaryItem.actionType }
    var details: ReviewDetails? { items.lazy.compactMap(\.reviewDetails).first }

    var memberTrackIDs: [Int64] {
        var ids = Set<Int64>()
        for item in items {
            ids.insert(item.trackId)
            if let related = item.relatedTrackId { ids.insert(related) }
            ids.formUnion(item.reviewDetails?.tracks.map(\.id) ?? [])
        }
        return ids.sorted()
    }

    var isMetadataConflict: Bool { actionType == "metadata_conflict" }

    static func groups(from items: [ReviewItem]) -> [ReviewGroup] {
        var grouped: [String: [ReviewItem]] = [:]
        var order: [String] = []
        for item in items {
            let key = item.groupKey ?? "legacy:\(item.id ?? -1)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key in grouped[key].map { ReviewGroup(key: key, items: $0) } }
    }
}

/// One group as the Review lists show it.
struct ReviewGroupItem: Identifiable, Equatable {
    enum Kind: Equatable { case duplicate, conflict }

    let key: String
    let kind: Kind
    /// The versions, by id (`Version A`, `B`, `C` follow this order).
    let members: [Track]
    /// The version the scan recommends keeping (the best one — also for variant groups, as the
    /// reference of `Lower bitrate` / `Same quality`).
    let recommendedID: Int64
    /// The scan says the versions are probably different versions of the recording: the
    /// recommendation is to keep them all.
    let recommendsKeepAll: Bool
    /// `lossless format, higher bitrate` — why the recommended one.
    let why: String
    let matchPercent: Int?
    /// Playlists each version is in.
    let usedIn: [Int64: Int]

    var id: String { key }
    var memberIDs: [Int64] { members.map { $0.id ?? -1 } }
    var recommended: Track? { members.first { $0.id == recommendedID } }
    /// `‹n› versions of “‹Title›”`.
    var title: String { recommended?.title ?? members.first?.title ?? "" }
    var artist: String { recommended?.artist ?? members.first?.artist ?? "" }
    var headline: String { "\(members.count) versions of “\(title)”" }

    /// `Version A`…
    func letter(of trackID: Int64) -> String {
        guard let index = members.firstIndex(where: { $0.id == trackID }) else { return "?" }
        let scalar = UnicodeScalar(UInt8(ascii: "A") + UInt8(min(index, 25)))
        return String(Character(scalar))
    }
}

// MARK: - Words

/// The words of Review: pure, so they are unit-tested (UC-COPY, §15.9).
enum ReviewPresentation {
    // MARK: Recommendation

    /// `Keep FLAC · 1,411 kbps — lossless format` (V-REV.E06c): names the file by what
    /// distinguishes it, never `Artist — Title`.
    static func recommendation(for group: ReviewGroupItem) -> String {
        if group.recommendsKeepAll { return "Keep all versions — probably different versions" }
        guard let track = group.recommended else { return "" }
        return "Keep \(formatAndBitrate(track)) — \(group.why)"
    }

    /// `FLAC · 1,411 kbps` / `MP3` / `Not downloaded`.
    static func formatAndBitrate(_ track: Track) -> String {
        guard track.availability().hasFile || track.organizedPath?.isEmpty == false else { return "not downloaded version" }
        let format = track.format.trimmingCharacters(in: .whitespaces).uppercased()
        var parts = [format.isEmpty ? "file" : format]
        if let bitrate = track.bitrate, bitrate > 0 { parts.append("\(bitrate.formatted(.number)) kbps") }
        return parts.joined(separator: " · ")
    }

    /// The scan's reasons in the mockup's words.
    static func why(reasons: [String], recommended: Track?, others: [Track]) -> String {
        if !reasons.isEmpty { return reasons.joined(separator: ", ") }
        if let recommended, DuplicateReviewRecommendation.hasRealFile(recommended),
           others.allSatisfy({ !DuplicateReviewRecommendation.hasRealFile($0) }) {
            return "the only downloaded version"
        }
        return "same quality, most complete tags"
    }

    /// The `Why` column: `Identical recording · 97 % match`.
    static func whyColumn(isVariant: Bool, matchPercent: Int?) -> String {
        let kind = isVariant ? "Same recording, different version" : "Identical recording"
        guard let matchPercent else { return kind }
        return "\(kind) · \(matchPercent) % match"
    }

    /// The version column: `Recommended — highest quality` or why not.
    static func versionLabel(for track: Track, in group: ReviewGroupItem) -> String {
        switch track.availability() {
        case .notDownloaded, .downloading: return "Not downloaded"
        case .failed: return "Download failed"
        case .fileMissing: return "File missing"
        case .local: break
        }
        if track.id == group.recommendedID { return group.recommendsKeepAll ? "Alternative" : "Recommended — \(group.why)" }
        guard let reference = group.recommended else { return "Alternative" }
        let mine = track.bitrate ?? 0
        let theirs = reference.bitrate ?? 0
        if mine < theirs { return "Lower bitrate" }
        if mine == theirs { return "Same quality" }
        return "Alternative"
    }

    // MARK: Consequence line (V-REV.N03, verbatim from review.html `#conseq`)

    static func consequenceSentence(_ mode: UnkeptMode) -> String {
        switch mode {
        case .trash:
            "Files of versions you don’t keep are moved to the Trash (you can put them back from there). Playlists and sync profiles are re-pointed to the kept version."
        case .hidden:
            "Versions you don’t keep stay on disk and in the library but no longer appear in All Tracks, albums or search. Playlists and sync profiles are re-pointed to the kept version."
        }
    }

    /// Under a group's actions: `1 other version stays in the library, hidden from lists · 3
    /// playlist entries are re-pointed to the kept version`.
    static func groupConsequence(others: Int, playlistEntries: Int, mode: UnkeptMode) -> String {
        let versions: String
        switch mode {
        case .trash: versions = "\(others) other \(others == 1 ? "version moves" : "versions move") to the Trash"
        case .hidden: versions = "\(others) other \(others == 1 ? "version stays" : "versions stay") in the library, hidden from lists"
        }
        guard playlistEntries > 0 else { return versions }
        return versions + " · \(playlistEntries) playlist \(playlistEntries == 1 ? "entry is" : "entries are") re-pointed to the kept version"
    }

    // MARK: Apply Recommended to All… (A-REV-APPLYALL)

    static func applyAllTitle(groups: Int) -> String { "Keep the recommended version in \(groups) groups?" }

    static func applyAllButton(groups: Int) -> String { "Keep Recommended in \(groups) Groups" }

    static func applyAllMessage(others: Int, playlistEntries: Int, mode: UnkeptMode) -> String {
        let head = mode == .trash
            ? "\(others) files of the other versions are moved to the Trash."
            : "\(others) other versions stay in the library, hidden from lists."
        return "\(head) \(playlistEntries) playlist entries are re-pointed to the kept versions. You can undo this in one step, or restore single groups in Resolved."
    }

    // MARK: Status-bar confirmations (the mockup's `MLM.say` calls)

    static func keptMessage(format: String?, title: String, hidden: Int, mode: UnkeptMode, playlistEntries: Int, trashFailures: Int) -> String {
        let word = format.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        var text = word.map { "Kept the \($0) version of “\(title)”" } ?? "Kept one version of “\(title)”"
        text += " · " + movedOrHidden(count: hidden, mode: mode)
        if playlistEntries > 0 { text += " · \(playlistEntries) playlist \(playlistEntries == 1 ? "entry" : "entries") re-pointed" }
        if trashFailures > 0 { text += " · " + couldntTrash(trashFailures) }
        return text
    }

    static func keptAllMessage(count: Int, title: String) -> String {
        "Kept all \(count) versions of “\(title)” — not duplicates"
    }

    static func bulkMessage(groups: Int, hidden: Int, mode: UnkeptMode, playlistEntries: Int, trashFailures: Int) -> String {
        var text = "Kept the recommended version in \(groups) groups · "
            + (mode == .trash ? "\(hidden) files moved to the Trash" : "\(hidden) versions hidden from lists")
            + " · \(playlistEntries) playlist entries re-pointed"
        if trashFailures > 0 { text += " · " + couldntTrash(trashFailures) }
        return text
    }

    static func mergedMessage(title: String, files: Int) -> String {
        "Merged tags of “\(title)” · \(files) files updated"
    }

    static func differentVersionsMessage(title: String) -> String {
        "Kept “\(title)” as different versions"
    }

    static func restoredMessage(title: String) -> String {
        "Restored “\(title)” — it is back in its tab"
    }

    /// `Can’t keep “Title” — its file is missing`.
    static func cantKeepFileMissing(title: String) -> String {
        "Can’t keep “\(title)” — its file is missing"
    }

    /// `3 groups skipped — the recommended version has no file`.
    static func groupsSkippedNoFile(_ count: Int) -> String {
        "\(count) \(count == 1 ? "group" : "groups") skipped — the recommended version has no file"
    }

    static func couldntTrash(_ count: Int) -> String {
        "Couldn’t move \(count) \(count == 1 ? "file" : "files") to the Trash"
    }

    static func cantUndoTrash(_ count: Int) -> String {
        "Can’t undo the Trash move — \(count) \(count == 1 ? "file is" : "files are") no longer in the Trash"
    }

    private static func movedOrHidden(count: Int, mode: UnkeptMode) -> String {
        switch mode {
        case .trash: "\(count) \(count == 1 ? "version" : "versions") moved to the Trash"
        case .hidden: "\(count) \(count == 1 ? "version" : "versions") hidden from lists"
        }
    }

    // MARK: Resolved

    /// `FLAC kept · 2 versions hidden from lists · 3 playlist entries re-pointed`.
    static func outcome(_ record: ReviewDecisionRecord?) -> String {
        guard let record else { return "Decided in an earlier version of MLM" }
        let c = record.consequences
        switch record.action {
        case .keepRecommended, .keepSelected:
            var text = "\((c.keptFormat ?? "One version").uppercased()) kept · "
                + movedOrHidden(count: c.hiddenCount, mode: record.unkeptMode ?? .hidden)
            if c.repointedPlaylistEntries > 0 {
                text += " · \(c.repointedPlaylistEntries) playlist \(c.repointedPlaylistEntries == 1 ? "entry" : "entries") re-pointed"
            }
            if c.trashFailures > 0 { text += " · \(c.trashFailures) couldn’t be moved" }
            return text
        case .keepAll, .keepBoth:
            return "Nothing changed · not proposed again"
        case .merge:
            let files = Set(c.tags.map(\.trackId)).count
            let fields = c.changedFields.joined(separator: ", ")
            return fields.isEmpty ? "Nothing changed · not proposed again"
                : "\(files) \(files == 1 ? "file" : "files") updated: \(fields)"
        }
    }

    /// `Duplicate` / `Conflict`.
    static func kindWord(_ kind: ReviewGroupItem.Kind) -> String { kind == .duplicate ? "Duplicate" : "Conflict" }

    // MARK: Header

    static let neverScanned = "Never scanned"

    /// Scan words in the header while idle: the last scan, or nothing when never scanned.
    static func lastScanLine(_ last: ReviewLastScan?) -> String? { last?.sentence }
}

// MARK: - Conflict fields

/// The tags a conflict compares, in the mockup's order (`FIELDS`).
enum ConflictField: String, CaseIterable, Identifiable, Sendable {
    case title, artist, albumArtist, album, genre, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .albumArtist: "Album artist"
        case .album: "Album"
        case .genre: "Genre"
        case .year: "Year"
        }
    }

    var tagField: TrackTagField {
        switch self {
        case .title: .title
        case .artist: .artist
        case .albumArtist: .albumArtist
        case .album: .album
        case .genre: .genre
        case .year: .year
        }
    }

    /// The value as shown (`""` = empty).
    func text(of track: Track) -> String {
        switch self {
        case .title: track.title.trimmingCharacters(in: .whitespaces)
        case .artist: track.artist.trimmingCharacters(in: .whitespaces)
        case .albumArtist: track.albumArtist.trimmingCharacters(in: .whitespaces)
        case .album: track.album.trimmingCharacters(in: .whitespaces)
        case .genre: (track.genre ?? "").trimmingCharacters(in: .whitespaces)
        case .year: track.year.map(String.init) ?? ""
        }
    }

    /// The value to write for `text`.
    func value(from text: String) -> TrackTagValue {
        switch self {
        case .genre: .text(text.isEmpty ? nil : text)
        case .year: .number(Int(text))
        default: .text(text)
        }
    }

    /// The fields whose values differ between `tracks`.
    static func differing(in tracks: [Track]) -> [ConflictField] {
        allCases.filter { field in Set(tracks.map { field.text(of: $0) }).count > 1 }
    }
}
