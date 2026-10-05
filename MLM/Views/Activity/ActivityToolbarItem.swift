import SwiftUI

// MARK: - Toolbar Activity item (P-ACTIVITY, UC-JOB-04)

/// The toolbar Activity item: idle = plain symbol; running = determinate ring + the oldest
/// running operation in words + `+‹k›`; waiting = `‹n› waiting for “Lexxar”`; needs attention =
/// `‹n› failed` until dismissed or fixed. Never colour only. The text gives way at narrow
/// widths (UC-TB-03 step 2, `ViewThatFits`) — the failure words stay longest. One bounce when a
/// job ends (not with Reduce Motion). Click: the Activity popover. Present in launch states too.
struct ActivityToolbarItem: View {
    var center: ActivityCenter = .shared
    @Bindable private var router = ActivityRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = ActivityPresentation.toolbarSummary(center)
        Button {
            router.isPopoverPresented.toggle()
        } label: {
            ViewThatFits(in: .horizontal) {
                label(summary, showRunning: true, showSecondary: true)
                label(summary, showRunning: false, showSecondary: true)
                label(summary, showRunning: false, showSecondary: false)
            }
        }
        .help(summary.isIdle ? "Activity ⌥⌘0" : summary.sentence)
        .accessibilityLabel("Activity")
        .accessibilityValue(summary.sentence)
        .popover(isPresented: $router.isPopoverPresented, arrowEdge: .bottom) {
            ActivityPopover(center: center)
        }
    }

    @ViewBuilder
    private func label(_ summary: ActivityPresentation.ToolbarSummary, showRunning: Bool, showSecondary: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if summary.isRunning {
                if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                symbol
            }
            let parts = [showRunning ? summary.runningText : nil,
                         showSecondary ? summary.waitingText : nil,
                         showSecondary ? summary.failedText : nil].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: "list.bullet.rectangle")
        if reduceMotion {
            image
        } else {
            image.symbolEffect(.bounce, value: center.finishedCount)
        }
    }
}

// MARK: - Popover (P-ACTIVITY-OPS in the popover, UC-JOB-05)

/// `Running` · `Needs attention` · `Recent`, footer `Open Activity Window ⌥⌘0`. A system
/// popover with a plain grouped form — no custom material. Each row opens its subject on
/// click (an explicit action); nothing here moves on its own.
struct ActivityPopover: View {
    let center: ActivityCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var clearQueueTarget: ActivityOperation?

    static let recentLimit = 5

    var body: some View {
        let running = center.activeOperations
        let attention = ActivityPresentation.attentionGroups(center)
        let recent = Array(center.finishedOperations.prefix(Self.recentLimit))
        VStack(spacing: 0) {
            Form {
                Section("Running") {
                    if running.isEmpty {
                        Text("Nothing is running.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(running) { op in
                        RunningRow(operation: op, center: center, clearQueue: { clearQueueTarget = op },
                                   open: { open(op.subject) })
                    }
                }
                Section {
                    if attention.isEmpty {
                        Text("Nothing needs attention.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(attention) { group in
                        AttentionRow(group: group, perform: { fix in
                            ActivitySubjectNavigator.perform(fix, group: group, center: center,
                                                             openWindow: openWindow, openSettings: openSettings)
                        }, open: { subject in open(subject) }, showLogs: {
                            showLogs(group.operationIDs.first)
                        })
                    }
                } header: {
                    HStack {
                        Text("Needs attention")
                        Spacer()
                        let failures = attention.filter { !$0.isWaiting }
                        if failures.contains(where: \.isRetryable) {
                            Button("Retry All") {
                                for group in failures where group.isRetryable {
                                    ActivitySubjectNavigator.retry(group, center: center)
                                }
                            }
                        }
                        if !failures.isEmpty {
                            Button("Dismiss") {
                                center.dismiss(failures.flatMap(\.operationIDs))
                            }
                            .help("The tracks keep their Download failed status and stay retryable from All Tracks.")
                        }
                    }
                }
                Section("Recent") {
                    if recent.isEmpty {
                        Text("Finished work appears here with its result.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recent) { op in
                        RecentRow(operation: op, open: { open(op.subject) })
                    }
                    if let backup = lastBackupLine {
                        HStack {
                            Text(backup)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Backup Settings") { openSettings(tab: .backup) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    ActivityRouter.shared.isPopoverPresented = false
                    ActivityRouter.shared.tab = .operations
                    openWindow(id: ActivityWindow.id)
                } label: {
                    Text("Open Activity Window") + Text("  ⌥⌘0").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Logs") {
                    ActivityRouter.shared.isPopoverPresented = false
                    ActivityRouter.shared.showLogs(for: nil)
                    openWindow(id: ActivityWindow.id)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
        }
        .frame(width: 400, height: 460)
        .confirmationDialog(clearQueueTitle, isPresented: clearQueueBinding, titleVisibility: .visible) {
            Button("Clear Waiting", role: .destructive) {
                clearQueueTarget?.controls.clearWaiting?()
                clearQueueTarget = nil
            }
            Button("Cancel", role: .cancel) { clearQueueTarget = nil }
        } message: {
            Text(ActivityQueueCopy.clearMessage(waiting: clearQueueTarget.map(ActivityPresentation.waitingItems) ?? 0))
        }
    }

    private var clearQueueBinding: Binding<Bool> {
        Binding(get: { clearQueueTarget != nil }, set: { if !$0 { clearQueueTarget = nil } })
    }

    private var clearQueueTitle: String {
        ActivityQueueCopy.clearTitle(waiting: clearQueueTarget.map(ActivityPresentation.waitingItems) ?? 0)
    }

    /// `Last backup: today 9:02 — 12,935 tracks` (P-ACTIVITY-OPS.N10).
    private var lastBackupLine: String? {
        guard let backup = center.finishedOperations.first(where: { $0.kind == .backup && $0.state == .completed }),
              let end = backup.endedAt else { return nil }
        let when = ActivityPresentation.shortTime(end)
        if let result = ActivityPresentation.resultText(backup) { return "Last backup: \(when) — \(result)" }
        return "Last backup: \(when)"
    }

    private func open(_ subject: ActivitySubject) {
        ActivitySubjectNavigator.open(subject, openWindow: openWindow, openSettings: openSettings)
    }

    private func showLogs(_ id: UUID?) {
        ActivityRouter.shared.isPopoverPresented = false
        ActivityRouter.shared.showLogs(for: id.flatMap(center.operation(id:)))
        openWindow(id: ActivityWindow.id)
    }
}

/// A-OPS-CLEARQUEUE copy (`activity.html`).
enum ActivityQueueCopy {
    static func clearTitle(waiting: Int) -> String {
        "Clear \(ActivityNoun(singular: "waiting analysis", plural: "waiting analyses").counted(waiting))?"
    }

    static func clearMessage(waiting: Int) -> String {
        let tracks = ActivityNoun.track.counted(waiting)
        return "The track being analysed now is finished. The other \(tracks) stay without loudness, fingerprint and similarity data until you run the analysis again in Settings ▸ Maintenance. No files or downloads are affected."
    }
}

// MARK: - Rows

/// The subject as a link (`“Warm-up”`), plain text when it no longer exists.
struct ActivitySubjectLink: View {
    let subject: ActivitySubject
    let open: () -> Void

    var body: some View {
        if let label = subject.linkLabel {
            if subject.isLinkable {
                Button(label, action: open)
                    .buttonStyle(.link)
                    .lineLimit(1)
            } else {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The honest controls of an active operation (UC-JOB-03).
struct ActivityControlButtons: View {
    let operation: ActivityOperation
    let center: ActivityCenter
    var clearQueue: () -> Void = {}

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if operation.controls.canPause {
                if operation.state == .paused {
                    Button("Resume") { center.resume(operation.id) }
                } else if operation.state == .running {
                    Button("Pause") { center.pause(operation.id) }
                }
            }
            if operation.controls.clearWaiting != nil, (operation.progress.waiting ?? 0) > 0 {
                Button("Clear Waiting…", action: clearQueue)
            }
            if operation.state == .queued, operation.controls.cancel == nil, case .turn = operation.wait {
                // A queued job that never started can always be dropped.
                Button("Cancel") { center.cancel(operation.id) }
            } else if operation.controls.canCancel {
                Button(operation.state == .queued ? "Cancel" : operation.controls.cancelStyle.title) {
                    center.cancel(operation.id)
                }
            }
        }
        .controlSize(.small)
    }
}

private struct RunningRow: View {
    let operation: ActivityOperation
    let center: ActivityCenter
    let clearQueue: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(operation.title)
                    .lineLimit(1)
                    .onTapGesture(perform: open)
                Spacer(minLength: Spacing.xs)
                if let progress = ActivityPresentation.progressText(operation.progress) {
                    Text(progress)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ActivityControlButtons(operation: operation, center: center, clearQueue: clearQueue)
            }
            if operation.state == .running, let fraction = operation.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            HStack(spacing: Spacing.xs) {
                if operation.state != .running {
                    Label(operation.state.word, systemImage: operation.state.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                if let line = ActivityPresentation.activeLine(operation) {
                    Text(line)
                        .lineLimit(2)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AttentionRow: View {
    let group: ActivityPresentation.AttentionGroup
    let perform: (ActivityFix) -> Void
    let open: (ActivitySubject) -> Void
    let showLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: group.isWaiting ? "externaldrive.badge.xmark" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(group.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.xs)
                if let fix = group.fix, let title = fix.buttonTitle {
                    Button(title) { perform(fix) }
                        .controlSize(.small)
                }
            }
            if let note = group.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !group.isWaiting {
                HStack(spacing: Spacing.xxs) {
                    if let subject = group.originSubject, subject.linkLabel != nil {
                        Text("From")
                        ActivitySubjectLink(subject: subject) { open(subject) }
                    }
                    if let date = group.originDate {
                        Text("· \(ActivityPresentation.shortTime(date))")
                    }
                    Text("·")
                    Button("Show in Logs", action: showLogs)
                        .buttonStyle(.link)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecentRow: View {
    let operation: ActivityOperation
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: operation.state.systemImage)
                .foregroundStyle(operation.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Group {
                if operation.subject.isLinkable {
                    Button(operation.title, action: open)
                        .buttonStyle(.link)
                } else {
                    Text(operation.title)
                }
            }
            .lineLimit(1)
            if let result = ActivityPresentation.resultText(operation) {
                Text("— \(result)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            if let end = operation.endedAt {
                Text(ActivityPresentation.shortTime(end))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(operation.state.word)
    }
}
