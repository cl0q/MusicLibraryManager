import AppKit
import SwiftUI

struct LogsTab: View {
    private let logger = AppLogger.shared

    @State private var levelFilter: LogLevelFilter = .all
    @State private var sourceFilter: LogSourceFilter = .all
    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""

    @State private var isPaused: Bool = false
    @State private var autoscrollEnabled: Bool = true
    @State private var wrapEnabled: Bool = false

    @State private var cachedResult: LogFeedResult?
    @State private var lastQuery: LogQuery?
    @State private var lastEntryCount: Int = 0

    private var currentQuery: LogQuery {
        LogQuery(level: levelFilter, source: sourceFilter, searchText: debouncedSearchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()

            if cachedResult?.isEmpty ?? true {
                emptyState
            } else {
                SelectableLogView(
                    entries: cachedResult?.rows ?? [],
                    wrapEnabled: wrapEnabled,
                    autoscrollEnabled: autoscrollEnabled,
                    isPaused: isPaused,
                    query: currentQuery
                )
            }
        }
        .background(Color.mlmBase)
        .onChange(of: levelFilter) { _, _ in recomputeIfNeeded() }
        .onChange(of: sourceFilter) { _, _ in recomputeIfNeeded() }
        .onChange(of: logger.entries.count) { _, _ in recomputeIfNeeded() }
        .task(id: searchText) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                debouncedSearchText = searchText
            } catch {
                // Task was cancelled — bail out
            }
        }
        .onChange(of: debouncedSearchText) { _, _ in recomputeIfNeeded() }
        .onAppear { recomputeIfNeeded() }
    }

    private func recomputeIfNeeded() {
        let newQuery = currentQuery
        let newCount = logger.entries.count
        if LogFeed.shouldRequery(
            previousQuery: lastQuery,
            previousEntryCount: lastEntryCount,
            newQuery: newQuery,
            newEntryCount: newCount
        ) {
            cachedResult = LogFeed.evaluate(entries: logger.entries, query: newQuery)
            lastQuery = newQuery
            lastEntryCount = newCount
        }
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            levelMenu

            sourceMenu

            searchField

            Spacer(minLength: 4)

            pauseToggle
            autoscrollToggle
            wrapToggle

            clearButton
            revealButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 32)
        .background(Color.mlmSurface)
        .accessibilityIdentifier("logs_toolbar")
    }

    // MARK: Level filter

    private var levelMenu: some View {
        let counts = cachedResult?.countsByFilter ?? [:]
        let count = counts[levelFilter] ?? 0
        return Menu {
            ForEach(LogLevelFilter.allCases) { filter in
                Button {
                    levelFilter = filter
                } label: {
                    let c = counts[filter] ?? 0
                    if levelFilter == filter {
                        Label("\(filter.label) (\(c))", systemImage: "checkmark")
                    } else {
                        Text("\(filter.label) (\(c))")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(levelFilter.label) (\(count))")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(MLMFont.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("logs_level_filter")
    }

    // MARK: Source filter

    private var sourceMenu: some View {
        let sources = cachedResult?.availableSources ?? []
        return Menu {
            Button {
                sourceFilter = .all
            } label: {
                if sourceFilter == .all {
                    Label("All sources", systemImage: "checkmark")
                } else {
                    Text("All sources")
                }
            }

            Divider()

            ForEach(sources, id: \.self) { src in
                Button {
                    sourceFilter = .exact(src)
                } label: {
                    if case .exact(let selected) = sourceFilter, selected == src {
                        Label(src, systemImage: "checkmark")
                    } else {
                        Text(src)
                    }
                }
            }

            Divider()

            Button {
                sourceFilter = .none
            } label: {
                if sourceFilter == .none {
                    Label("(no source)", systemImage: "checkmark")
                } else {
                    Text("(no source)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                Text(sourceMenuLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(MLMFont.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("logs_source_filter")
    }

    private var sourceMenuLabel: String {
        switch sourceFilter {
        case .all: return "All sources"
        case .none: return "(no source)"
        case .exact(let s): return s
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.mlmInkMuted)
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(.plain)
                .font(MLMFont.body)
                .accessibilityIdentifier("logs_search_field")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.mlmInkMuted)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("logs_search_clear_button")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.mlmRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 120)
    }

    // MARK: Toggles

    private var pauseToggle: some View {
        Button {
            isPaused.toggle()
        } label: {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help(isPaused ? "Resume" : "Pause")
        .accessibilityIdentifier("logs_pause_toggle")
    }

    private var autoscrollToggle: some View {
        Button {
            autoscrollEnabled.toggle()
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12))
                .foregroundColor(autoscrollEnabled ? .accentColor : .mlmInkMuted)
        }
        .buttonStyle(.plain)
        .help(autoscrollEnabled ? "Autoscroll on" : "Autoscroll off")
        .accessibilityIdentifier("logs_autoscroll_toggle")
    }

    private var wrapToggle: some View {
        Button {
            wrapEnabled.toggle()
        } label: {
            Image(systemName: wrapEnabled ? "text.wordwrap" : "text.alignleft")
                .font(.system(size: 12))
                .foregroundColor(wrapEnabled ? .accentColor : .mlmInkMuted)
        }
        .buttonStyle(.plain)
        .help(wrapEnabled ? "Wrap on" : "Wrap off")
        .accessibilityIdentifier("logs_wrap_toggle")
    }

    // MARK: Actions

    private var clearButton: some View {
        Button("Clear") {
            logger.clear()
        }
        .font(MLMFont.muted)
        .buttonStyle(.plain)
        .accessibilityIdentifier("logs_clear_button")
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([logger.logFileURL])
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help(logger.logFileURL.path)
        .accessibilityIdentifier("logs_reveal_button")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 24))
                .foregroundColor(.mlmInkMuted)
            Text(levelFilter == .all && sourceFilter == .all && debouncedSearchText.isEmpty
                 ? "No log entries"
                 : "No entries match the filter")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
            Text("Application events stream here in real time")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("logs_empty_state")
    }
}

// MARK: - SelectableLogView

private struct SelectableLogView: NSViewRepresentable {
    let entries: [AppLogger.LogEntry]
    let wrapEnabled: Bool
    let autoscrollEnabled: Bool
    let isPaused: Bool
    let query: LogQuery

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityIdentifier("logs_text_view")

        if !wrapEnabled {
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let storage = tv.textStorage else { return }

        let coord = context.coordinator

        // Handle pause — accumulate entries but do not render
        if isPaused {
            coord.pendingEntries = entries
            coord.wasPaused = true
            return
        }

        // If we were paused and are now resuming, flush pending entries
        let activeEntries: [AppLogger.LogEntry]
        if coord.wasPaused {
            activeEntries = coord.pendingEntries ?? entries
            coord.pendingEntries = nil
            coord.wasPaused = false
            coord.justResumedAutoscroll = autoscrollEnabled
            // Force rebuild on resume
            coord.storedFingerprint = nil
        } else {
            activeEntries = entries
        }

        // Handle empty
        guard !activeEntries.isEmpty else {
            if storage.length > 0 {
                storage.setAttributedString(NSAttributedString())
            }
            coord.storedFingerprint = nil
            coord.lastRenderedID = nil
            return
        }

        // Update wrap mode on the text container
        if coord.currentWrap != wrapEnabled {
            coord.currentWrap = wrapEnabled
            if let container = tv.textContainer {
                if wrapEnabled {
                    container.containerSize = NSSize(
                        width: tv.textContainer?.containerSize.width ?? 1000,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                } else {
                    container.containerSize = NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                }
            }
        }

        let atBottom = isAtBottom(scroll)

        // Build the incoming fingerprint (autoscroll deliberately excluded — A1)
        let incoming = LogRenderFingerprint(query: query, wrapEnabled: wrapEnabled)

        // Use the tested Module 4 plan logic for the stale-render fix
        let plan = LogTextRenderer.plan(
            storedFingerprint: coord.storedFingerprint,
            incomingFingerprint: incoming,
            lastRenderedEntryID: coord.lastRenderedID,
            entries: activeEntries
        )

        switch plan {
        case .rebuild:
            let rendered = LogTextRenderer.attributedString(for: activeEntries, wrap: wrapEnabled)
            storage.setAttributedString(rendered)
            coord.storedFingerprint = incoming
            coord.lastRenderedID = activeEntries.last?.id

        case .appendFrom(let index):
            let tail = Array(activeEntries[index...])
            let rendered = LogTextRenderer.attributedString(for: tail, wrap: wrapEnabled)
            storage.append(NSAttributedString(string: "\n"))
            storage.append(rendered)
            coord.storedFingerprint = incoming
            coord.lastRenderedID = activeEntries.last?.id

        case .noChange:
            break
        }

        // Autoscroll logic — state stays in the view, never in the fingerprint
        if autoscrollEnabled {
            if coord.justResumedAutoscroll || atBottom {
                tv.scrollToEndOfDocument(nil)
            }
        }
        coord.justResumedAutoscroll = false
    }

    private func isAtBottom(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return true }
        return scroll.documentVisibleRect.maxY >= doc.bounds.height - 20
    }

    final class Coordinator {
        var storedFingerprint: LogRenderFingerprint?
        var lastRenderedID: UUID?
        var currentWrap: Bool = false
        var wasPaused: Bool = false
        var pendingEntries: [AppLogger.LogEntry]?
        var justResumedAutoscroll: Bool = false
    }
}
