import AppKit
import SwiftUI

struct LogsTab: View {
    private let logger = AppLogger.shared

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case warnings = "Warn+"
        case errors = "Errors"
        var id: String { rawValue }
    }

    /// `nil` source filter == "all sources". Otherwise filter to entries
    /// whose `source` matches this string. `""` matches entries with no
    /// source attached.
    @State private var filter: Filter = .all
    @State private var sourceFilter: String? = nil
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                SelectableLogView(entries: filteredEntries)
            }
        }
        .background(Color.mlmBase)
    }

    private var filteredEntries: [AppLogger.LogEntry] {
        let base: [AppLogger.LogEntry]
        switch filter {
        case .all:      base = logger.entries
        case .warnings: base = logger.entries.filter { $0.level == .warning || $0.level == .error }
        case .errors:   base = logger.entries.filter { $0.level == .error }
        }

        let sourceFiltered: [AppLogger.LogEntry]
        if let sf = sourceFilter {
            if sf.isEmpty {
                sourceFiltered = base.filter { $0.source == nil }
            } else {
                sourceFiltered = base.filter { $0.source == sf }
            }
        } else {
            sourceFiltered = base
        }

        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sourceFiltered }
        return sourceFiltered.filter { entry in
            entry.message.lowercased().contains(query) ||
            (entry.source?.lowercased().contains(query) ?? false)
        }
    }

    /// Unique source strings present in the buffer, alphabetised.
    /// Drives the Source picker entries.
    private var availableSources: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in logger.entries {
            if let s = e.source, !seen.contains(s) {
                seen.insert(s)
                out.append(s)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(filteredEntries.count) of \(logger.entries.count)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .frame(minWidth: 96, alignment: .leading)

                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                sourceMenu

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.logFileURL])
                } label: {
                    Label("Reveal Log", systemImage: "doc.text.magnifyingglass")
                }
                .font(MLMFont.muted)
                .buttonStyle(.plain)
                .help(logger.logFileURL.path)

                Button("Clear") {
                    logger.clear()
                }
                .font(MLMFont.muted)
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.mlmInkMuted)
                TextField("Logs durchsuchen (Nachricht oder Source)…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(MLMFont.body)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                sourceFilter = nil
            } label: {
                HStack {
                    if sourceFilter == nil { Image(systemName: "checkmark") }
                    Text("Alle Sources")
                }
            }
            Divider()
            ForEach(availableSources, id: \.self) { src in
                Button {
                    sourceFilter = src
                } label: {
                    HStack {
                        if sourceFilter == src { Image(systemName: "checkmark") }
                        Text(src)
                    }
                }
            }
            if logger.entries.contains(where: { $0.source == nil }) {
                Divider()
                Button {
                    sourceFilter = ""
                } label: {
                    HStack {
                        if sourceFilter == "" { Image(systemName: "checkmark") }
                        Text("(ohne Source)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                Text(sourceMenuLabel)
                    .lineLimit(1)
            }
            .font(MLMFont.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sourceMenuLabel: String {
        switch sourceFilter {
        case .none:       return "Alle Sources"
        case .some(""):   return "(ohne Source)"
        case .some(let s): return s
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 24))
                .foregroundColor(.mlmInkMuted)
            Text(filter == .all ? "No log entries" : "No entries match the filter")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
            Text("Application events stream here in real time")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SelectableLogView

/// NSTextView-backed log renderer so the user can select and copy any text
/// across rows — something SwiftUI's LazyVStack cannot do.
private struct SelectableLogView: NSViewRepresentable {
    let entries: [AppLogger.LogEntry]

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

        guard !entries.isEmpty else {
            if storage.length > 0 {
                storage.setAttributedString(NSAttributedString())
                context.coordinator.lastRenderedID = nil
            }
            return
        }

        let atBottom = isAtBottom(scroll)
        let coord = context.coordinator

        // Decide whether to append incrementally or rebuild from scratch.
        let newEntries: [AppLogger.LogEntry]
        let rebuild: Bool

        if let lastID = coord.lastRenderedID,
           let lastIdx = entries.firstIndex(where: { $0.id == lastID }) {
            let tail = entries[(lastIdx + 1)...]
            guard !tail.isEmpty else { return }
            newEntries = Array(tail)
            rebuild = false
        } else {
            newEntries = entries
            rebuild = true
            storage.setAttributedString(NSAttributedString())
        }

        storage.append(buildChunk(newEntries, prependNewline: storage.length > 0))
        coord.lastRenderedID = entries.last?.id

        if atBottom || rebuild {
            tv.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Helpers

    private func buildChunk(_ chunk: [AppLogger.LogEntry], prependNewline: Bool) -> NSAttributedString {
        let mono11  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let mono9b  = NSFont.monospacedSystemFont(ofSize: 9,  weight: .bold)
        let mono11m = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let nlAttrs: [NSAttributedString.Key: Any] = [.font: mono11]

        let out = NSMutableAttributedString()
        for (i, entry) in chunk.enumerated() {
            if prependNewline || i > 0 {
                out.append(NSAttributedString(string: "\n", attributes: nlAttrs))
            }

            // Timestamp — HH:mm:ss.SSS is exactly 12 chars; fixed width via padding
            out.append(NSAttributedString(
                string: entry.formattedTime.padding(toLength: 12, withPad: " ", startingAt: 0) + "  ",
                attributes: [.font: mono11, .foregroundColor: NSColor.secondaryLabelColor]
            ))

            // Level — right-pad to 5 chars (ERROR is longest)
            out.append(NSAttributedString(
                string: entry.level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0) + "  ",
                attributes: [.font: mono9b, .foregroundColor: levelColor(entry.level)]
            ))

            // Source — right-pad to 14 chars
            if let source = entry.source {
                out.append(NSAttributedString(
                    string: String(source.prefix(14)).padding(toLength: 14, withPad: " ", startingAt: 0) + "  ",
                    attributes: [.font: mono11m, .foregroundColor: NSColor.controlAccentColor]
                ))
            }

            // Message
            out.append(NSAttributedString(
                string: entry.message,
                attributes: [.font: mono11, .foregroundColor: NSColor.labelColor]
            ))
        }
        return out
    }

    private func isAtBottom(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return true }
        return scroll.documentVisibleRect.maxY >= doc.bounds.height - 20
    }

    private func levelColor(_ level: AppLogger.Level) -> NSColor {
        switch level {
        case .info:    return .systemBlue
        case .warning: return .systemOrange
        case .error:   return .systemRed
        case .debug:   return .systemGray
        }
    }

    final class Coordinator {
        var lastRenderedID: UUID? = nil
    }
}
