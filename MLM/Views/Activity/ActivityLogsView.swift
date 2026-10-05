import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Activity ▸ Logs (P-ACTIVITY-LOGS, UC-JOB-06): level filter (`All · Info and above · Warnings
/// and above · Errors · Debug only`, with counts) and source filter, both remembered; search
/// (⌘F); a labelled `Pause` / `Resume` with its state (`Live` / `Paused · ‹n› new lines held`);
/// `Wrap lines`; `Copy`; `Export…`; `Show Log File in Finder`; `Clear…` (A-LOGS-CLEAR); the
/// deep-link filter from `Show in Logs` with `Show All Lines`.
///
/// Fast with tens of thousands of lines: the filter runs only when the query or the buffer
/// changes (`LogFeed.shouldRequery`), and the text view appends new lines instead of rebuilding
/// (`LogTextRenderer.plan`).
struct ActivityLogsView: View {
    private let logger = AppLogger.shared
    @Bindable private var router = ActivityRouter.shared

    @AppStorage("activity.logs.level") private var levelRaw = LogLevelFilter.all.rawValue
    @AppStorage("activity.logs.source") private var sourceRaw = LogSourceFilter.all.storageValue
    @AppStorage("activity.logs.wrap") private var wrapEnabled = false

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pausedAfterID: UUID?
    @State private var isPaused = false
    @State private var cachedResult: LogFeedResult?
    @State private var lastQuery: LogQuery?
    @State private var lastEntryCount = 0
    @State private var lastEntryID: UUID?
    @State private var proxy = LogTextViewProxy()
    @State private var isConfirmingClear = false
    @State private var isExporting = false
    @State private var exportDocument = LogTextDocument(text: "")
    @FocusState private var searchFocused: Bool

    private var level: LogLevelFilter { LogLevelFilter(rawValue: levelRaw) ?? .all }
    private var source: LogSourceFilter { LogSourceFilter(storageValue: sourceRaw) }

    private var currentQuery: LogQuery {
        var query = LogQuery(level: level, source: source, searchText: debouncedSearchText)
        if let focus = router.logFocus {
            query.window = DateInterval(start: focus.start, end: max(focus.end ?? .distantFuture, focus.start))
        }
        return query
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()
            if let focus = router.logFocus {
                focusLine(focus)
                Divider()
            }
            if cachedResult?.isEmpty ?? true {
                emptyState
            } else {
                SelectableLogView(
                    entries: cachedResult?.rows ?? [],
                    wrapEnabled: wrapEnabled,
                    isPaused: isPaused,
                    query: currentQuery,
                    proxy: proxy,
                    showOnlySource: { sourceRaw = LogSourceFilter.exact($0).storageValue },
                    showOnlyOperation: { date in
                        if let op = ActivityCenter.shared.allOperations.first(where: { op in
                            date >= op.startedAt && date <= (op.endedAt ?? .distantFuture)
                        }) {
                            router.showLogs(for: op)
                        }
                    }
                )
            }
            Divider()
            footer
        }
        .onChange(of: levelRaw) { _, _ in recomputeIfNeeded() }
        .onChange(of: sourceRaw) { _, _ in recomputeIfNeeded() }
        .onChange(of: router.logFocus) { _, _ in recomputeIfNeeded() }
        .onChange(of: logger.entries.count) { _, _ in recomputeIfNeeded() }
        .onChange(of: logger.entries.last?.id) { _, _ in recomputeIfNeeded() }
        .task(id: searchText) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                debouncedSearchText = searchText
            } catch {}
        }
        .onChange(of: debouncedSearchText) { _, _ in recomputeIfNeeded() }
        .onAppear { recomputeIfNeeded() }
        .focusedSceneValue(\.activityLogSearch, ActivityLogSearchFocus { searchFocused = true })
        .alert("Clear the log view?", isPresented: $isConfirmingClear) {
            // Not destructive: the file keeps everything (UC-SHEET-14, A-LOGS-CLEAR).
            Button("Clear") { logger.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(logger.entries.count.formatted(.number)) lines held in memory are removed from this view. The log file on disk keeps everything and can still be exported.")
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .plainText,
                      defaultFilename: "MLM Log.txt") { _ in }
        .fileDialogMessage("Choose where to save the log lines.")
    }

    // MARK: Requery

    private func recomputeIfNeeded() {
        let entries = logger.entries
        let query = currentQuery
        // `count` alone stops changing once the buffer is full (5,000); the last id keeps moving.
        let changed = entries.last?.id != lastEntryID
        if changed || LogFeed.shouldRequery(previousQuery: lastQuery, previousEntryCount: lastEntryCount,
                                            newQuery: query, newEntryCount: entries.count) {
            cachedResult = LogFeed.evaluate(entries: entries, query: query)
            lastQuery = query
            lastEntryCount = entries.count
            lastEntryID = entries.last?.id
        }
    }

    // MARK: Toolbar

    private var toolbarRow: some View {
        let counts = cachedResult?.countsByFilter ?? [:]
        return HStack(spacing: Spacing.s) {
            Picker("Level", selection: $levelRaw) {
                ForEach(LogLevelFilter.allCases) { filter in
                    Text("\(filter.label) \((counts[filter] ?? 0).formatted(.number))").tag(filter.rawValue)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker("Source", selection: $sourceRaw) {
                Text("All sources").tag(LogSourceFilter.all.storageValue)
                Divider()
                ForEach(cachedResult?.availableSources ?? [], id: \.self) { name in
                    Text(name).tag(LogSourceFilter.exact(name).storageValue)
                }
                if case .exact(let chosen) = source, !(cachedResult?.availableSources.contains(chosen) ?? false) {
                    Text(chosen).tag(sourceRaw)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            TextField("Search", text: $searchText, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .frame(minWidth: 140, maxWidth: 240)

            Spacer(minLength: Spacing.s)

            Button(isPaused ? "Resume" : "Pause") {
                if isPaused {
                    isPaused = false
                    pausedAfterID = nil
                } else {
                    isPaused = true
                    pausedAfterID = logger.entries.last?.id
                }
            }
            Text(pauseStateText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Toggle("Wrap lines", isOn: $wrapEnabled)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
    }

    private var pauseStateText: String {
        guard isPaused else { return "Live" }
        let entries = logger.entries
        let held: Int
        if let id = pausedAfterID, let index = entries.lastIndex(where: { $0.id == id }) {
            held = entries.count - index - 1
        } else {
            held = entries.count
        }
        return "Paused · \(ActivityNoun(singular: "new line", plural: "new lines").counted(held)) held"
    }

    private func focusLine(_ focus: ActivityLogFocus) -> some View {
        HStack(spacing: Spacing.s) {
            Text("Showing the \((cachedResult?.matched ?? 0).formatted(.number)) lines of “\(focus.title)”")
                .font(.callout)
            Spacer()
            Button("Show All Lines") { router.logFocus = nil }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            Text("Shows the newest \(5_000.formatted(.number)) lines. Older lines are in the log file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") { copyLines() }
                .help("Copies the selection, or all shown lines when nothing is selected.")
            Button("Export…") {
                exportDocument = LogTextDocument(text: shownText)
                isExporting = true
            }
            Button("Show Log File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([logger.logFileURL])
            }
            .help(logger.logFileURL.path)
            Button("Clear…") { isConfirmingClear = true }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
    }

    private var shownText: String {
        (cachedResult?.rows ?? []).map(LogTextRenderer.plainLine).joined(separator: "\n")
    }

    private func copyLines() {
        let text = proxy.selectedText ?? shownText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if logger.entries.isEmpty {
            ContentUnavailableView("No log lines", systemImage: "text.alignleft",
                                   description: Text("What MLM does is written here as it happens."))
        } else {
            ContentUnavailableView {
                Label("No lines match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No log lines match the current filters.")
            } actions: {
                Button("Clear Filters") {
                    levelRaw = LogLevelFilter.all.rawValue
                    sourceRaw = LogSourceFilter.all.storageValue
                    searchText = ""
                    debouncedSearchText = ""
                    router.logFocus = nil
                }
            }
        }
    }
}

/// ⌘F in the Activity window focuses the log search (UC-KEY-25).
struct ActivityLogSearchFocus {
    let focus: () -> Void
}

extension FocusedValues {
    @Entry var activityLogSearch: ActivityLogSearchFocus?
}

/// Plain-text export of the shown lines.
struct LogTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Lets SwiftUI read the text view's selection (`Copy`).
@MainActor
final class LogTextViewProxy {
    weak var textView: NSTextView?

    var selectedText: String? {
        guard let textView, textView.selectedRange().length > 0,
              let storage = textView.textStorage else { return nil }
        return (storage.string as NSString).substring(with: textView.selectedRange())
    }
}

// MARK: - Read-only selectable log text (NSTextView, UC-KIT-37)

private struct SelectableLogView: NSViewRepresentable {
    let entries: [AppLogger.LogEntry]
    let wrapEnabled: Bool
    let isPaused: Bool
    let query: LogQuery
    let proxy: LogTextViewProxy
    let showOnlySource: (String) -> Void
    let showOnlyOperation: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = LogTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Spacing.xl, height: Spacing.xxs)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Log")
        textView.coordinator = context.coordinator
        proxy.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? LogTextView, let storage = tv.textStorage else { return }
        let coord = context.coordinator
        coord.showOnlySource = showOnlySource
        coord.showOnlyOperation = showOnlyOperation
        proxy.textView = tv

        if isPaused {
            coord.wasPaused = true
            return
        }
        if coord.wasPaused {
            coord.wasPaused = false
            coord.storedFingerprint = nil
        }

        if coord.currentWrap != wrapEnabled {
            coord.currentWrap = wrapEnabled
            tv.textContainer?.widthTracksTextView = wrapEnabled
            tv.textContainer?.containerSize = NSSize(
                width: wrapEnabled ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            coord.storedFingerprint = nil
        }

        guard !entries.isEmpty else {
            if storage.length > 0 { storage.setAttributedString(NSAttributedString()) }
            coord.storedFingerprint = nil
            coord.lastRenderedID = nil
            coord.rendered = []
            return
        }

        let atBottom = scroll.documentVisibleRect.maxY >= (scroll.documentView?.bounds.height ?? 0) - 20
        let incoming = LogRenderFingerprint(query: query, wrapEnabled: wrapEnabled)
        switch LogTextRenderer.plan(storedFingerprint: coord.storedFingerprint, incomingFingerprint: incoming,
                                    lastRenderedEntryID: coord.lastRenderedID, entries: entries) {
        case .rebuild:
            storage.setAttributedString(LogTextRenderer.attributedString(for: entries, wrap: wrapEnabled))
            coord.rendered = entries
        case .appendFrom(let index):
            let tail = Array(entries[index...])
            storage.append(NSAttributedString(string: "\n"))
            storage.append(LogTextRenderer.attributedString(for: tail, wrap: wrapEnabled))
            coord.rendered.append(contentsOf: tail)
        case .noChange:
            break
        }
        coord.storedFingerprint = incoming
        coord.lastRenderedID = entries.last?.id
        // Autoscroll is implicit: follow while at the bottom (P-ACTIVITY-LOGS.E05).
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }

    @MainActor
    final class Coordinator {
        var storedFingerprint: LogRenderFingerprint?
        var lastRenderedID: UUID?
        var currentWrap: Bool?
        var wasPaused = false
        var rendered: [AppLogger.LogEntry] = []
        var showOnlySource: (String) -> Void = { _ in }
        var showOnlyOperation: (Date) -> Void = { _ in }

        /// The entry on the line that holds `characterIndex`.
        func entry(atCharacter characterIndex: Int, in text: String) -> AppLogger.LogEntry? {
            let prefix = (text as NSString).substring(to: min(characterIndex, (text as NSString).length))
            let line = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            return line < rendered.count ? rendered[line] : nil
        }
    }
}

/// The system text menu plus the two filters taken from the clicked line (CM-LOGS-TEXT):
/// act on the text · narrow the view · system items.
private final class LogTextView: NSTextView {
    weak var coordinator: SelectableLogView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard let coordinator, let entry = coordinator.entry(atCharacter: index, in: string) else { return menu }
        var items: [NSMenuItem] = []
        if let source = entry.source, !source.isEmpty {
            items.append(ClosureMenuItem(title: "Show Only “\(source)” Lines") { coordinator.showOnlySource(source) })
        }
        items.append(ClosureMenuItem(title: "Show Only This Operation") { coordinator.showOnlyOperation(entry.timestamp) })
        // After the text actions (Copy, Select All) and before the system items.
        let insertAt = min(menu.items.firstIndex { $0.action == #selector(NSText.selectAll(_:)) }.map { $0 + 1 } ?? 0,
                           menu.items.count)
        menu.insertItem(.separator(), at: insertAt)
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: insertAt + 1 + offset) }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
