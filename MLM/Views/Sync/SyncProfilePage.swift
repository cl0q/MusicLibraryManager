import SwiftUI

/// V-SYNC-DETAIL: a sync profile as a sidebar destination (DEC-027). In the content scaffold:
/// banner (interrupted sync or library drive away, one at a time), the detail header (name,
/// destination, connection, capacity, Sync Now / Pause · Resume · Cancel / More), then one list
/// with the sections Content · Plan · Options · Last sync. Every word comes from
/// `SyncProfileState` — the same as the sidebar row's second line.
struct SyncProfilePage: View {
    let profileID: Int64

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var actions: ShellActions?

    var body: some View {
        if let vm = container.syncViewModel, let profile = vm.profile(profileID) {
            SyncProfilePageContent(vm: vm, profile: profile)
                .id(profileID)
        } else {
            ContentScaffold(showsDriveBanner: false) {
                if (container.syncViewModel?.profiles ?? []).isEmpty {
                    ContentUnavailableView {
                        Label("No sync profiles yet.", systemImage: "externaldrive")
                    } description: {
                        Text("A sync profile is a destination — a player, a USB stick or any folder — plus the playlists and tracks you want on it. MLM shows what will change before it copies anything.")
                    } actions: {
                        Button("New Sync Profile…") { actions?.newSyncProfile() }
                    }
                } else {
                    ContentUnavailableView("Sync profile not found", systemImage: "externaldrive",
                                           description: Text("It may have been deleted."))
                }
            }
            .modifier(WindowTitleModifier())
        }
    }
}

private struct SyncProfilePageContent: View {
    let vm: SyncViewModel
    let profile: SyncProfile

    var body: some View {
        let id = profile.id ?? -1
        // A TimelineView keeps `2 hours ago` honest without reloading anything.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = vm.state(for: profile, now: context.date)
            ContentScaffold(showsDriveBanner: false) {
                SyncProfileSections(vm: vm, profile: profile, state: state)
                    .statusBarText(statusText)
            } header: {
                VStack(spacing: 0) {
                    if let banner = state.banner {
                        SyncBanner(banner: banner, profile: profile, vm: vm)
                    }
                    SyncProfileHeader(vm: vm, profile: profile, state: state)
                }
            }
            .modifier(WindowTitleModifier())
        }
        .task(id: id) {
            await vm.loadContent(id)
        }
    }

    private var statusText: String? {
        guard let id = profile.id else { return nil }
        if (vm.contentCounts[id] ?? 0) == 0 { return "Nothing in this profile yet" }
        if let total = vm.plans[id]?.preview?.totalTracks { return "\(StatusBarText.tracks(total)) in this profile" }
        return nil
    }
}

// MARK: - Banner (UC-LAYOUT-02)

private struct SyncBanner: View {
    let banner: SyncProfileState.Banner
    let profile: SyncProfile
    let vm: SyncViewModel

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: banner.kind == .interrupted ? "eject" : "externaldrive.badge.xmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).fontWeight(.semibold)
                if let detail = banner.detail { Text(detail) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            if banner.kind == .interrupted, vm.run(for: profile) != nil {
                Button("Cancel Sync") { vm.cancel(profile) }
            }
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

// MARK: - Header

private struct SyncProfileHeader: View {
    let vm: SyncViewModel
    let profile: SyncProfile
    let state: SyncProfileState

    var body: some View {
        let id = profile.id ?? -1
        let run = vm.run(for: profile)
        HStack(alignment: .top, spacing: Spacing.l) {
            Image(systemName: SyncDestination.volumePath(for: profile.outputFolder) == nil ? "folder" : "externaldrive")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(profile.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: Spacing.s) {
                    Text(profile.outputFolder.isEmpty ? "No destination" : profile.outputFolder)
                        .monospaced()
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Label(state.connectionText, systemImage: state.isConnected ? "checkmark.circle" : "eject")
                        .font(.subheadline)
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    if !state.headerFacts.isEmpty {
                        Text("· " + state.headerFacts.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                capacity(id)
                if let run, run.phase != .waitingForDevice {
                    VStack(alignment: .leading, spacing: 2) {
                        if let fraction = state.runFraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        HStack {
                            Text(state.runText ?? "").bold().monospacedDigit()
                            if let item = run.currentItem {
                                Text(run.phase == .paused ? "Continues with: \(item)" : item)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .font(.subheadline)
                    }
                    .frame(maxWidth: 520)
                } else if let reason = state.syncNowDisabledReason, run == nil {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.m)
            HStack(spacing: Spacing.s) {
                if let run {
                    if run.phase == .running { Button("Pause") { vm.pause(profile) } }
                    if run.phase == .paused {
                        Button("Resume") { vm.resume(profile) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Cancel") { vm.cancel(profile) }
                } else {
                    Button("Sync Now") { vm.syncNow(profile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.canSyncNow)
                        .help(state.syncNowDisabledReason ?? "Copy the plan to “\(SyncDestination.deviceName(for: profile.outputFolder))”")
                }
                Menu {
                    SyncProfileMenu(profile: profile, place: .more)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// V-SYNC-DETAIL.N01: used / to add / free on the device, with a legend in words.
    @ViewBuilder
    private func capacity(_ id: Int64) -> some View {
        if state.isConnected, let capacity = vm.capacities[id], capacity.total > 0 {
            let used = capacity.total - capacity.free
            let toAdd = vm.plans[id]?.preview?.totalNewSize ?? 0
            VStack(alignment: .leading, spacing: 2) {
                Gauge(value: Double(min(capacity.total, used + toAdd)), in: 0...Double(capacity.total)) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .frame(maxWidth: 520)
                .accessibilityLabel("Space on the device")
                Text(capacityLegend(used: used, toAdd: toAdd, free: capacity.free, total: capacity.total))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if !state.isConnected {
            Text("Capacity is unknown while the device is not connected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func capacityLegend(used: Int64, toAdd: Int64, free: Int64, total: Int64) -> String {
        var parts = ["Used \(SyncProfileState.bytes(used))"]
        if toAdd > 0 { parts.append("To add \(SyncProfileState.bytes(toAdd))") }
        parts.append("Free \(SyncProfileState.bytes(free)) of \(SyncProfileState.bytes(total))")
        return parts.joined(separator: " · ")
    }
}
