import SwiftUI

/// **Review** (V-REV, DEC-021/028/041/044): `Duplicates · Conflicts · Resolved` (`Albums` is
/// Wave 4 and hidden). The scan is an Activity operation (`Run Scan`, ⌘R); every decision is one
/// undo step with a status-bar confirmation; unkept versions either stay in the library hidden
/// from lists or go to the Trash (a session choice); versions are compared in the shared track
/// table. UC-LAYOUT-01…05, UC-PRIM-09, UC-KEY-30.
struct ReviewView: View {
    /// `Show in Review` from Info: that group opens expanded.
    let focusTrackID: Int64?
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    @State private var model: ReviewModel?
    @SceneStorage("review.tab") private var storedTab = ReviewTab.duplicates.rawValue
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var showsApplyAll = false
    @State private var showsFailureDetails = false
    @State private var writesTags = false

    private var tab: ReviewTab {
        let tab = ReviewTab(rawValue: storedTab) ?? .duplicates
        return tab == .albums ? .duplicates : tab
    }

    var body: some View {
        ContentScaffold(showsDriveBanner: true) {
            content
        } header: {
            banners
        } scopeBar: {
            scopeBar
        }
        .modifier(WindowTitleModifier())
        .task { await setUp() }
        .task(id: container.searchCoordinator.filter(for: .review)) {
            model?.filter = container.searchCoordinator.filter(for: .review)
        }
        .task(id: LibraryDriveState.current(container)) {
            model?.drive = LibraryDriveState.current(container)
        }
        .onChange(of: model?.scan.finishedCount) { _, _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .pendingTagWritesDidChange)) { _ in
            Task { writesTags = await TagWriteSetting.isEnabled(container.configRepository) }
        }
        .alert(applyAllTitle, isPresented: $showsApplyAll) {
            Button(applyAllButton, role: model?.effectiveMode == .trash ? .destructive : nil) { applyRecommendedToAll() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(applyAllMessage)
        }
    }

    private func setUp() async {
        if model == nil, let dependencies = ReviewModel.Dependencies.live(container) {
            let created = ReviewModel(dependencies: dependencies)
            created.filter = container.searchCoordinator.filter(for: .review)
            created.drive = LibraryDriveState.current(container)
            model = created
        }
        guard let model else { return }
        model.scan.statusBar = statusBar
        writesTags = await TagWriteSetting.isEnabled(container.configRepository)
        await model.scan.loadLastScan()
        await model.reload()
        openFocused()
    }

    /// `Show in Review`: the group of the track opens (P3: nothing else moves).
    private func openFocused() {
        guard let focusTrackID, let model, let group = model.group(containing: focusTrackID) else { return }
        storedTab = (group.kind == .conflict ? ReviewTab.conflicts : .duplicates).rawValue
        expanded.insert(group.key)
        selection = group.key
    }

    // MARK: Scope bar (UC-SCOPE-01)

    private var scopeBar: some View {
        let items = ReviewTab.allCases.map { tab in
            ScopeBarItem(id: tab, title: tab.title, count: model?.count(for: tab), hidesWhenEmpty: tab == .albums)
        }
        return ScopeBar(
            items: items,
            selection: Binding(get: { tab }, set: { storedTab = $0.rawValue }),
            countNoun: .items
        ) { EmptyView() }
    }

    // MARK: Banners (header slot)

    @ViewBuilder
    private var banners: some View {
        if let model {
            VStack(spacing: 0) {
                if let failure = model.scanFailure {
                    ReviewBanner(symbol: "exclamationmark.triangle", tint: .orange) {
                        Text("\(Text(failure.headline).fontWeight(.semibold)) Groups from the scan before are still shown.")
                    } actions: {
                        Button("Details") { showsFailureDetails = true }
                            .popover(isPresented: $showsFailureDetails) {
                                Text(failure.details)
                                    .textSelection(.enabled)
                                    .frame(width: 320, alignment: .leading)
                                    .padding(Spacing.m)
                            }
                        Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                    }
                }
                if model.drive.isOffline, let name = model.drive.volumeName {
                    // V-REV.N02: deciding works offline; Trash and listening need the files.
                    ReviewBanner(symbol: "info.circle", tint: .secondary) {
                        Text("You can still decide. Previews are paused, and Move to Trash is off until “\(name)” is connected.")
                    } actions: { EmptyView() }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let model {
            VStack(spacing: 0) {
                scanRow(model)
                Divider()
                switch tab {
                case .duplicates, .albums:
                    if model.isNothingToReview {
                        nothingToReview(model)
                    } else {
                        duplicatesTab(model)
                    }
                case .conflicts:
                    if model.isNothingToReview {
                        nothingToReview(model)
                    } else {
                        conflictsTab(model)
                    }
                case .resolved:
                    ReviewResolvedView(model: model, statusBar: statusBar, search: search)
                }
            }
            .statusBarText(statusText(model))
        } else {
            ContentUnavailableView("No library is open", systemImage: "square.stack.3d.up")
        }
    }

    private func statusText(_ model: ReviewModel) -> String? {
        guard model.isLoaded else { return nil }
        switch tab {
        case .duplicates, .albums:
            return model.duplicateCount == 1 ? "1 duplicate group" : "\(model.duplicateCount.formatted(.number)) duplicate groups"
        case .conflicts:
            return model.conflictCount == 1 ? "1 conflict" : "\(model.conflictCount.formatted(.number)) conflicts"
        case .resolved:
            return model.resolvedCount == 1 ? "1 decision" : "\(model.resolvedCount.formatted(.number)) decisions"
        }
    }

    // MARK: Scan row (V-REV.E02, E03)

    private func scanRow(_ model: ReviewModel) -> some View {
        HStack(spacing: Spacing.m) {
            if let echo = model.scanEcho {
                ProgressView().controlSize(.small)
                Text(echo.toolbarText)
                    .monospacedDigit()
                if let fraction = echo.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 160)
                }
                Text("Decisions you already made are kept.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Show in Activity") { ActivityRouter.shared.showPopover() }
                    .buttonStyle(.link)
                Button("Cancel Scan") { model.scan.cancel() }
            } else {
                Text(model.lastScan?.sentence ?? ReviewPresentation.neverScanned)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Run Scan") { model.scan.startWithConfirmation(statusBar: statusBar) }
                    .disabled(model.scan.blockedReason != nil)
                    .help(model.scan.blockedReason ?? "Compare the fingerprints of the library for duplicates and tag conflicts")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.background)
    }

    // MARK: Empty (V-REV.N10)

    private func nothingToReview(_ model: ReviewModel) -> some View {
        ContentUnavailableView {
            Label("Nothing to review", systemImage: "checkmark.circle")
        } description: {
            Text(model.lastScan == nil
                 ? "Nothing has been scanned yet. Run a scan to look for duplicates and tag conflicts."
                 : "No duplicates or tag conflicts are waiting. Run a scan after importing more music.")
        } actions: {
            Button("Run Scan") { model.scan.startWithConfirmation(statusBar: statusBar) }
                .buttonStyle(.borderedProminent)
                .disabled(model.scan.blockedReason != nil)
            Button("Show Resolved") { storedTab = ReviewTab.resolved.rawValue }
        }
    }

    private func noResults(_ what: String) -> some View {
        ContentUnavailableView {
            Label("No results", systemImage: "magnifyingglass")
        } description: {
            Text("No \(what) matches the search.")
        } actions: {
            Button("Clear Filters") { search?.clear() }
        }
    }

    // MARK: Duplicates (V-REV.N03, N04, E06)

    private func duplicatesTab(_ model: ReviewModel) -> some View {
        VStack(spacing: 0) {
            unkeptRow(model)
            Divider()
            let groups = model.visibleDuplicates
            if model.duplicates.isEmpty {
                ContentUnavailableView {
                    Label("No duplicates", systemImage: "checkmark.circle")
                } description: {
                    Text("Every group has a decision. Run a scan after importing more music.")
                }
            } else if groups.isEmpty {
                noResults("duplicate group")
            } else {
                ReviewGroupList(model: model, groups: groups, expanded: $expanded, selection: $selection,
                                writesTags: writesTags, onTrackActivated: onTrackActivated, decide: decide, search: search)
            }
        }
    }

    /// `Unkept versions: ○ Stay in library, hidden from lists ○ Move to Trash` + the consequence
    /// + `Apply Recommended to All…` (V-REV.N03/N04).
    private func unkeptRow(_ model: ReviewModel) -> some View {
        let trashRefusal = model.trashRefusal
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text("Unkept versions:").fontWeight(.semibold)
            HStack(spacing: Spacing.m) {
                ReviewRadio(title: "Stay in library, hidden from lists", isOn: model.unkeptMode == .hidden, help: nil) {
                    model.setUnkeptMode(.hidden)
                }
                ReviewRadio(title: "Move to Trash", isOn: model.unkeptMode == .trash, help: trashRefusal) {
                    model.setUnkeptMode(.trash)
                }
                .disabled(trashRefusal != nil)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unkept versions")
            Text(ReviewPresentation.consequenceSentence(model.effectiveMode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Apply Recommended to All \(model.visibleDuplicates.count.formatted(.number))…") { showsApplyAll = true }
                .disabled(model.visibleDuplicates.isEmpty)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.background)
    }

    // MARK: Conflicts (V-REV.E08a)

    private func conflictsTab(_ model: ReviewModel) -> some View {
        VStack(spacing: 0) {
            Text(writesTags
                 ? "The same recording with different tags. Choose the value to keep for each field; the result is written to every version — to the database and, because Write tags to files is on, to the files."
                 : "The same recording with different tags. Choose the value to keep for each field; the result is written to every version.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(.background)
            Divider()
            let groups = model.visibleConflicts
            if model.conflicts.isEmpty {
                ContentUnavailableView {
                    Label("No tag conflicts", systemImage: "checkmark.circle")
                } description: {
                    Text("Versions of the same recording with different tags appear here.")
                }
            } else if groups.isEmpty {
                noResults("conflict group")
            } else {
                ReviewGroupList(model: model, groups: groups, expanded: $expanded, selection: $selection,
                                writesTags: writesTags, onTrackActivated: onTrackActivated, decide: decide, search: search)
            }
        }
    }

    // MARK: Deciding

    private func decide(_ plans: [ReviewGroupPlan], _ actionName: String) {
        guard let model else { return }
        // Where the decided group was in the list, so the group that follows it is selected.
        let before = (tab == .conflicts ? model.visibleConflicts : model.visibleDuplicates).map(\.key)
        let index = selection.flatMap { before.firstIndex(of: $0) }
        Task {
            await model.apply(plans, actionName: actionName, undo: undo, statusBar: statusBar)
            // The next group stays selected so ↓ Return works through the list.
            if let selection, model.group(withKey: selection) == nil {
                self.selection = nextSelection(model, previousIndex: index)
            }
        }
    }

    /// The group now at the place the decided one had (the next one), or the last one.
    private func nextSelection(_ model: ReviewModel, previousIndex: Int?) -> String? {
        let list = tab == .conflicts ? model.visibleConflicts : model.visibleDuplicates
        guard !list.isEmpty else { return nil }
        return list[min(previousIndex ?? 0, list.count - 1)].key
    }

    // MARK: Apply Recommended to All… (A-REV-APPLYALL)

    private var applyGroups: [ReviewGroupItem] { model?.visibleDuplicates ?? [] }

    private var applyAllTitle: String { ReviewPresentation.applyAllTitle(groups: applyGroups.count) }

    private var applyAllButton: String { ReviewPresentation.applyAllButton(groups: applyGroups.count) }

    private var applyAllMessage: String {
        let skipped = applyGroups.filter { ReviewModel.recommendedHasNoFile($0) }.count
        let kept = applyGroups.filter { !$0.recommendsKeepAll && !ReviewModel.recommendedHasNoFile($0) }
        let others = kept.reduce(0) { $0 + $1.members.count - 1 }
        let entries = kept.reduce(0) { sum, group in
            sum + group.members.reduce(0) { $0 + ($1.id == group.recommendedID ? 0 : (group.usedIn[$1.id ?? -1] ?? 0)) }
        }
        let text = ReviewPresentation.applyAllMessage(others: others, playlistEntries: entries, mode: model?.effectiveMode ?? .hidden)
        return skipped > 0 ? text + " " + ReviewPresentation.groupsSkippedNoFile(skipped) + "." : text
    }

    private func applyRecommendedToAll() {
        guard let model else { return }
        let plans = model.visibleDuplicates.filter { !ReviewModel.recommendedHasNoFile($0) }.map { model.plan(keepRecommendedIn: $0) }
        decide(plans, "Keep Recommended Versions")
    }
}

// MARK: - Radio

/// One option of the session choice: a radio that can be disabled with its reason as help (a
/// native radio group can't disable a single option).
private struct ReviewRadio: View {
    let title: String
    let isOn: Bool
    let help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isOn ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Banner

/// A screen-specific banner under the window banner: quiet tinted opaque fill, a symbol, a
/// sentence, at most two buttons.
private struct ReviewBanner<Message: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let message: () -> Message
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            message()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            actions()
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background {
            ZStack {
                Rectangle().fill(.background)
                Rectangle().fill(.quaternary)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
