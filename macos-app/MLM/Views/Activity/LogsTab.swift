import AppKit
import SwiftUI

/// Logs tab within the ActivityPanel.
///
/// Streams the in-memory ring buffer of `AppLogger.shared`. Supports a
/// level filter (All / Warn+ / Error) and a "Reveal in Finder" button
/// that opens the on-disk log file.
struct LogsTab: View {
    private let logger = AppLogger.shared

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case warnings = "Warn+"
        case errors = "Errors"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .background(Color.mlmBase)
    }

    private var filteredEntries: [AppLogger.LogEntry] {
        switch filter {
        case .all:
            return logger.entries
        case .warnings:
            return logger.entries.filter { $0.level == .warning || $0.level == .error }
        case .errors:
            return logger.entries.filter { $0.level == .error }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("\(filteredEntries.count) of \(logger.entries.count)")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)

            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

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
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                        Divider().opacity(0.3)
                    }
                }
            }
            .onChange(of: logger.entries.count) { _, _ in
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: AppLogger.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.mlmInkMuted)
                .frame(width: 80, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(levelColor(entry.level))
                .frame(width: 36)

            if let source = entry.source {
                Text(source)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(width: 70, alignment: .leading)
            }

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.mlmInkPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private func levelColor(_ level: AppLogger.Level) -> Color {
        switch level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .debug: .gray
        }
    }

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
