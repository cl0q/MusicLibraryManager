import SwiftUI

/// Duplicates and metadata conflicts share one review workflow. Decisions
/// mutate only the database and always retain an undo snapshot.
struct ReviewQueueView: View {
    enum ReviewSection: Hashable {
        case duplicates
        case conflicts
        case resolved
    }

    @Environment(\.container) private var container
    @State private var viewModel: ReviewQueueViewModel?
    @State private var selectedSection: ReviewSection = .duplicates
    @State private var selectedGroupKey: String?
    @State private var manuallyKeptTrackID: Int64?
    @State private var metadataSources: [ReviewMetadataField: Int64] = [:]
    @State private var toastGroupKey: String?
    @State private var toastText: String?

    /// When opened from a track inspector, the matching pending group expands.
    var focusTrackID: Int64?

    var body: some View {
        Group {
            if let viewModel {
                reviewContent(viewModel)
            } else {
                ProgressView("Loading Review…")
            }
        }
        .task {
            guard viewModel == nil,
                  let analysisRepository = container.analysisRepository,
                  let trackRepository = container.trackRepository else { return }
            let model = ReviewQueueViewModel(
                analysisRepository: analysisRepository,
                trackRepository: trackRepository
            )
            viewModel = model
            await model.loadReviews()
            focus(on: focusTrackID, in: model)
        }
        .onChange(of: focusTrackID) { _, trackID in
            guard let viewModel else { return }
            focus(on: trackID, in: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in
            guard let viewModel, !viewModel.isScanning else { return }
            Task { await viewModel.loadReviews() }
        }
    }

    @ViewBuilder
    private func reviewContent(_ viewModel: ReviewQueueViewModel) -> some View {
        VStack(spacing: 0) {
            header(viewModel)
            Divider()

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmAttention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.mlmAttention.opacity(0.12))
            }

            sectionPicker(viewModel)

            if viewModel.isLoading {
                Spacer()
                ProgressView("Loading Review…")
                Spacer()
            } else {
                sectionContent(viewModel)
            }
        }
        .background(Color.mlmBase)
        .overlay(alignment: .bottomTrailing) {
            if let toastText, let toastGroupKey {
                resolutionToast(text: toastText, groupKey: toastGroupKey, viewModel: viewModel)
                    .padding(16)
            }
        }
    }

    private func header(_ viewModel: ReviewQueueViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review")
                    .font(MLMFont.pageTitle)
                Spacer()
                if viewModel.isScanning {
                    Button("Cancel scan") {
                        viewModel.cancelDeepScan()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        viewModel.startDeepScan()
                    } label: {
                        Label("Run scan", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if viewModel.isScanning, let progress = viewModel.scanProgress {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                    Text("Comparing \(progress.current.formatted()) of \(progress.total.formatted())…")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
            } else if viewModel.scanWasCancelled {
                Text("Scan cancelled. Existing review decisions were left unchanged.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            } else if let result = viewModel.scanResult {
                Text("Last scan: \(result.pairsCompared.formatted()) comparisons · \(result.duplicatesFound) duplicate groups · \(result.conflictsFlagged) metadata conflicts")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            } else {
                Text("Find possible duplicate recordings and metadata conflicts by comparing audio fingerprints.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
        }
        .padding(16)
    }

    private func sectionPicker(_ viewModel: ReviewQueueViewModel) -> some View {
        Picker("Review category", selection: $selectedSection) {
            Text("Duplicates \(duplicateGroups(in: viewModel).count)").tag(ReviewSection.duplicates)
            Text("Conflicts \(conflictGroups(in: viewModel).count)").tag(ReviewSection.conflicts)
            Text("Resolved \(viewModel.resolvedGroups.count)").tag(ReviewSection.resolved)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func sectionContent(_ viewModel: ReviewQueueViewModel) -> some View {
        switch selectedSection {
        case .duplicates:
            groupList(duplicateGroups(in: viewModel), type: .duplicates, viewModel: viewModel)
        case .conflicts:
            groupList(conflictGroups(in: viewModel), type: .conflicts, viewModel: viewModel)
        case .resolved:
            resolvedList(viewModel)
        }
    }

    @ViewBuilder
    private func groupList(
        _ groups: [ReviewGroup],
        type: ReviewSection,
        viewModel: ReviewQueueViewModel
    ) -> some View {
        if groups.isEmpty {
            emptyState(type: type, viewModel: viewModel)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groups) { group in
                        reviewGroupCard(group, viewModel: viewModel)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func emptyState(type: ReviewSection, viewModel: ReviewQueueViewModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: type == .conflicts ? "checkmark.circle" : "doc.on.doc")
                .font(.system(size: 32))
                .foregroundColor(type == .conflicts ? .mlmSuccess : .mlmInkMuted)
            Text(emptyTitle(for: type, viewModel: viewModel))
                .font(MLMFont.bodyBold)
            Text(emptyDescription(for: type, viewModel: viewModel))
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !viewModel.isScanning && viewModel.scanResult == nil && !viewModel.scanWasCancelled {
                Button("Run scan") {
                    viewModel.startDeepScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reviewGroupCard(_ group: ReviewGroup, viewModel: ReviewQueueViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(groupTitle(group, viewModel: viewModel))
                        .font(MLMFont.bodyBold)
                    Text(groupReason(group))
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                    if let recommendation = group.details?.recommendation {
                        Text(recommendationText(recommendation, group: group, viewModel: viewModel))
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                }
                Spacer()
                Text(group.isMetadataConflict ? "Metadata conflict" : "Duplicate group")
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmAttention)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.mlmAttention.opacity(0.15), in: Capsule())
            }

            if selectedGroupKey == group.key {
                Divider()
                groupDetail(group, viewModel: viewModel)
            }

            HStack {
                Button(selectedGroupKey == group.key ? "Hide details" : "Review group") {
                    if selectedGroupKey == group.key {
                        selectedGroupKey = nil
                    } else {
                        select(group)
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                if viewModel.resolvingGroupKeys.contains(group.key) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Keep all") {
                        Task {
                            if await viewModel.keepAll(group) {
                                showUndo(for: group, text: "All versions kept")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.mlmSurface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mlmEdge, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func groupDetail(_ group: ReviewGroup, viewModel: ReviewQueueViewModel) -> some View {
        if group.isMetadataConflict {
            metadataConflictDetail(group, viewModel: viewModel)
        } else {
            duplicateDetail(group, viewModel: viewModel)
        }
    }

    private func duplicateDetail(_ group: ReviewGroup, viewModel: ReviewQueueViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(group.memberTrackIDs, id: \.self) { trackID in
                trackRow(trackID: trackID, group: group, viewModel: viewModel)
            }

            Divider()
            HStack {
                Button("Keep recommended") {
                    Task {
                        if await viewModel.keepRecommended(group) {
                            showUndo(for: group, text: "Recommended version kept")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Picker("Keep version", selection: manualKeepBinding(for: group)) {
                    ForEach(group.memberTrackIDs, id: \.self) { trackID in
                        Text(trackName(trackID, group: group, viewModel: viewModel)).tag(trackID)
                    }
                }
                .frame(maxWidth: 250)

                Button("Keep selected") {
                    guard let manuallyKeptTrackID else { return }
                    Task {
                        if await viewModel.keepManually(group, trackID: manuallyKeptTrackID) {
                            showUndo(for: group, text: "Selected version kept")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(manuallyKeptTrackID == nil)

                Button("Never suggest again") {
                    Task {
                        if await viewModel.dismiss(group) {
                            showUndo(for: group, text: "Group will not be suggested again")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if let explanation = group.details?.variant?.explanation {
                Label(explanation, systemImage: "music.note")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
            Text("Keeping all clears duplicate markers. Media files are not renamed, moved, or deleted.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
    }

    private func trackRow(trackID: Int64, group: ReviewGroup, viewModel: ReviewQueueViewModel) -> some View {
        let track = viewModel.track(for: trackID)
        let snapshot = group.details?.tracks.first { $0.id == trackID }
        let isRecommended = group.details?.recommendation?.trackId == trackID
        return HStack(spacing: 10) {
            Image(systemName: isRecommended ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isRecommended ? .mlmSuccess : .mlmInkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRecommended ? "Recommended" : "Alternative")
                    .font(MLMFont.badge)
                    .foregroundColor(isRecommended ? .mlmSuccess : .mlmInkSecondary)
                Text(track?.format.uppercased() ?? snapshot?.format?.uppercased() ?? "Unknown format")
                    .font(MLMFont.bodyBold)
                Text(trackName(trackID, group: group, viewModel: viewModel))
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
            Spacer()
            Text(bitrateText(track: track, snapshot: snapshot))
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkSecondary)
            Text(track?.formattedDuration ?? snapshot?.duration.map(formatDuration) ?? "—")
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkSecondary)
            Text(track?.organizedPath ?? snapshot?.organizedPath ?? sourceText(track: track, snapshot: snapshot))
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)
            if let track, track.isLocal, let playback = container.playbackViewModel {
                Button("Preview") {
                    Task { await playback.playTrack(track) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(sourceText(track: track, snapshot: snapshot))
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkMuted)
            }
        }
        .padding(8)
        .background(isRecommended ? Color.mlmSuccess.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func metadataConflictDetail(_ group: ReviewGroup, viewModel: ReviewQueueViewModel) -> some View {
        let candidates = group.memberTrackIDs.compactMap(viewModel.track(for:))
        if candidates.count < 2 {
            Text("The source tracks are no longer available, so this conflict can only be kept as separate versions.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
            Button("These are different versions — keep both") {
                Task {
                    if await viewModel.keepAll(group) {
                        showUndo(for: group, text: "Versions kept separately")
                    }
                }
            }
            .buttonStyle(.bordered)
        } else {
            let sourceA = candidates[0]
            let sourceB = candidates[1]
            let sourceAID = sourceA.id ?? 0
            let sourceBID = sourceB.id ?? 0
            let fields = conflictingFields(for: group, sourceA: sourceA, sourceB: sourceB)
            VStack(alignment: .leading, spacing: 10) {
                Text("Same recording; choose the value to keep for each highlighted field.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Field").font(MLMFont.sectionLabel)
                        Text("Version A").font(MLMFont.sectionLabel)
                        Text("Version B").font(MLMFont.sectionLabel)
                        Text("Keep").font(MLMFont.sectionLabel)
                    }
                    ForEach(fields, id: \.self) { field in
                        GridRow {
                            Text(field.label)
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmAttention)
                            Text(metadataValue(field, track: sourceA))
                                .font(MLMFont.body)
                            Text(metadataValue(field, track: sourceB))
                                .font(MLMFont.body)
                            Picker("Keep \(field.label)", selection: metadataBinding(field, defaultID: sourceAID)) {
                                Text("A").tag(sourceAID)
                                Text("B").tag(sourceBID)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 96)
                        }
                    }
                }
                .padding(10)
                .background(Color.mlmAttention.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Use all from A") {
                        for field in fields { metadataSources[field] = sourceAID }
                    }
                    .buttonStyle(.bordered)
                    Button("Use all from B") {
                        for field in fields { metadataSources[field] = sourceBID }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("These are different versions — keep both") {
                        Task {
                            if await viewModel.keepAll(group) {
                                showUndo(for: group, text: "Versions kept separately")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Text(metadataPreview(fields: fields, sourceA: sourceA, sourceB: sourceB))
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                Text("Applies to the database only. Media files are not renamed or moved.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)

                Button("Apply merge") {
                    let merge = mergedMetadata(fields: fields, sourceA: sourceA, sourceB: sourceB)
                    Task {
                        if await viewModel.mergeMetadata(group, merge: merge) {
                            showUndo(for: group, text: "Metadata merge applied")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Never suggest again") {
                    Task {
                        if await viewModel.dismiss(group) {
                            showUndo(for: group, text: "Group will not be suggested again")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func resolvedList(_ viewModel: ReviewQueueViewModel) -> some View {
        if viewModel.resolvedGroups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30))
                    .foregroundColor(.mlmInkMuted)
                Text("No resolved reviews")
                    .font(MLMFont.bodyBold)
                Text("Resolved duplicate and metadata decisions appear here and can be restored.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.resolvedGroups) { group in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(groupTitle(group, viewModel: viewModel))
                            .font(MLMFont.bodyBold)
                        Text(resolutionDescription(group))
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                    Spacer()
                    if group.canUndo {
                        Button("Restore") {
                            Task { _ = await viewModel.undo(group) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.resolvingGroupKeys.contains(group.key))
                    } else {
                        Text("Earlier decision")
                            .font(MLMFont.badge)
                            .foregroundColor(.mlmInkMuted)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private func resolutionToast(text: String, groupKey: String, viewModel: ReviewQueueViewModel) -> some View {
        HStack(spacing: 12) {
            Text(text)
                .font(MLMFont.muted)
            Button("Undo") {
                guard let group = viewModel.resolvedGroups.first(where: { $0.key == groupKey }) else { return }
                Task {
                    if await viewModel.undo(group) {
                        toastGroupKey = nil
                        toastText = nil
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    private func duplicateGroups(in viewModel: ReviewQueueViewModel) -> [ReviewGroup] {
        viewModel.pendingGroups.filter { !$0.isMetadataConflict }
    }

    private func conflictGroups(in viewModel: ReviewQueueViewModel) -> [ReviewGroup] {
        viewModel.pendingGroups.filter(\.isMetadataConflict)
    }

    private func focus(on trackID: Int64?, in viewModel: ReviewQueueViewModel) {
        guard let trackID, let group = viewModel.group(containing: trackID) else { return }
        selectedSection = group.isMetadataConflict ? .conflicts : .duplicates
        select(group)
    }

    private func select(_ group: ReviewGroup) {
        selectedGroupKey = group.key
        manuallyKeptTrackID = group.details?.recommendation?.trackId ?? group.memberTrackIDs.first
        let sourceID = group.memberTrackIDs.first ?? 0
        metadataSources = Dictionary(uniqueKeysWithValues: ReviewMetadataField.allCases.map { ($0, sourceID) })
    }

    private func showUndo(for group: ReviewGroup, text: String) {
        selectedGroupKey = nil
        toastGroupKey = group.key
        toastText = text
    }

    private func groupTitle(_ group: ReviewGroup, viewModel: ReviewQueueViewModel) -> String {
        guard let firstID = group.memberTrackIDs.first else { return "Review group" }
        let track = viewModel.track(for: firstID)
        let snapshot = group.details?.tracks.first { $0.id == firstID }
        let title = track?.title ?? snapshot?.title ?? "Unknown title"
        let artist = track?.artist ?? snapshot?.artist ?? "Unknown artist"
        return "\(group.memberTrackIDs.count) versions of \"\(title)\" — \(artist)"
    }

    private func groupReason(_ group: ReviewGroup) -> String {
        let score = group.details?.evidence?.fingerprintSimilarity ?? group.details?.similarityScore
        let scoreText = score.map { "audio fingerprint \(Int(($0 * 100).rounded()))% match" } ?? "matching audio fingerprints"
        if group.details?.variant?.isVariant == true {
            return "Same recording, different version (\(scoreText))"
        }
        if group.isMetadataConflict {
            let fields = group.details?.conflictingFields.map(displayFieldName).joined(separator: ", ") ?? "metadata"
            return "Metadata conflict in \(fields) (\(scoreText))"
        }
        return "Identical recording (\(scoreText))"
    }

    private func recommendationText(
        _ recommendation: ReviewRecommendation,
        group: ReviewGroup,
        viewModel: ReviewQueueViewModel
    ) -> String {
        if recommendation.action == .keepBoth {
            return "Recommendation: keep both — \(recommendation.reasons.joined(separator: ", "))"
        }
        let name = recommendation.trackId.map { trackName($0, group: group, viewModel: viewModel) } ?? "this version"
        let reasons = recommendation.reasons.isEmpty ? "best available quality" : recommendation.reasons.joined(separator: ", ")
        return "Recommended: keep \(name) — \(reasons)"
    }

    private func trackName(_ trackID: Int64, group: ReviewGroup, viewModel: ReviewQueueViewModel) -> String {
        if let track = viewModel.track(for: trackID) {
            return "\(track.artist) — \(track.title)"
        }
        if let snapshot = group.details?.tracks.first(where: { $0.id == trackID }) {
            return "\(snapshot.artist) — \(snapshot.title)"
        }
        return "Unavailable version"
    }

    private func bitrateText(track: Track?, snapshot: ReviewTrackSnapshot?) -> String {
        if let bitrate = track?.bitrate ?? snapshot?.bitrate {
            return "\(bitrate / 1000) kbps"
        }
        return "—"
    }

    private func sourceText(track: Track?, snapshot: ReviewTrackSnapshot?) -> String {
        if track?.isLocal == true || snapshot?.organizedPath?.isEmpty == false {
            return "Local"
        }
        let format = track?.format ?? snapshot?.format ?? ""
        return format.isEmpty ? "Not downloaded" : format.capitalized
    }

    private func manualKeepBinding(for group: ReviewGroup) -> Binding<Int64> {
        Binding(
            get: { manuallyKeptTrackID ?? group.memberTrackIDs.first ?? 0 },
            set: { manuallyKeptTrackID = $0 }
        )
    }

    private func conflictingFields(for group: ReviewGroup, sourceA: Track, sourceB: Track) -> [ReviewMetadataField] {
        let stored = Set(group.details?.conflictingFields ?? [])
        let fields = ReviewMetadataField.allCases.filter { field in
            stored.contains(field.rawValue) || metadataValue(field, track: sourceA) != metadataValue(field, track: sourceB)
        }
        return fields.isEmpty ? [.title, .artist] : fields
    }

    private func metadataBinding(_ field: ReviewMetadataField, defaultID: Int64) -> Binding<Int64> {
        Binding(
            get: { metadataSources[field] ?? defaultID },
            set: { metadataSources[field] = $0 }
        )
    }

    private func mergedMetadata(
        fields: [ReviewMetadataField],
        sourceA: Track,
        sourceB: Track
    ) -> ReviewMetadataMerge {
        var merged = ReviewMetadataMerge(fields: Set(fields), source: sourceA)
        for field in fields {
            guard metadataSources[field] == sourceB.id else { continue }
            switch field {
            case .title: merged.title = sourceB.title
            case .artist: merged.artist = sourceB.artist
            case .albumArtist: merged.albumArtist = sourceB.albumArtist
            case .album: merged.album = sourceB.album
            case .genre: merged.genre = sourceB.genre
            case .year: merged.year = sourceB.year
            }
        }
        return merged
    }

    private func metadataPreview(
        fields: [ReviewMetadataField],
        sourceA: Track,
        sourceB: Track
    ) -> String {
        let values = fields.map { field -> String in
            let source = metadataSources[field] == sourceB.id ? sourceB : sourceA
            return "\(field.label) \"\(metadataValue(field, track: source))\""
        }
        return "After merge: \(values.joined(separator: ", "))"
    }

    private func metadataValue(_ field: ReviewMetadataField, track: Track) -> String {
        switch field {
        case .title: track.title
        case .artist: track.artist
        case .albumArtist: track.albumArtist
        case .album: track.album
        case .genre: track.genre?.isEmpty == false ? track.genre! : "—"
        case .year: track.year.map(String.init) ?? "—"
        }
    }

    private func resolutionDescription(_ group: ReviewGroup) -> String {
        switch group.details?.resolutionSnapshot?.action {
        case ReviewResolutionAction.keepRecommended.rawValue: "Recommended version kept"
        case ReviewResolutionAction.keepManual.rawValue: "Selected version kept"
        case ReviewResolutionAction.keepAll.rawValue: "All versions kept"
        case ReviewResolutionAction.mergeMetadata.rawValue: "Metadata merged"
        case ReviewResolutionAction.dismiss.rawValue: "Never suggest again"
        case nil where !group.canUndo: "Earlier decision cannot be restored"
        default: "Resolved"
        }
    }

    private func emptyTitle(for type: ReviewSection, viewModel: ReviewQueueViewModel) -> String {
        switch type {
        case .duplicates:
            viewModel.scanResult == nil ? "Find duplicates and conflicts" : "No duplicates found — your library is clean"
        case .conflicts: "No metadata conflicts"
        case .resolved: "No resolved reviews"
        }
    }

    private func emptyDescription(for type: ReviewSection, viewModel: ReviewQueueViewModel) -> String {
        switch type {
        case .duplicates:
            viewModel.scanResult == nil
                ? "A scan compares local audio fingerprints and creates review proposals without changing your library."
                : "Run another scan after importing more music."
        case .conflicts: "Conflicting tags for the same recording appear here."
        case .resolved: "Resolved decisions can be restored from this list."
        }
    }

    private func displayFieldName(_ field: String) -> String {
        ReviewMetadataField(rawValue: field)?.label.lowercased() ?? field.replacingOccurrences(of: "_", with: " ")
    }

    private func formatDuration(_ duration: Int) -> String {
        String(format: "%d:%02d", duration / 60, duration % 60)
    }
}
