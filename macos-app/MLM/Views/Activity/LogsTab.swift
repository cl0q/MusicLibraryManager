import SwiftUI

/// Logs tab within the ActivityPanel.
///
/// Shows a streaming log of application events from AppLogger.
struct LogsTab: View {
    private let logger = AppLogger.shared

    var body: some View {
        VStack(spacing: 0) {
            if logger.entries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .background(Color.mlmBase)
    }

    private var logList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(logger.entries.count) entries")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                Spacer()
                Button("Clear") {
                    logger.clear()
                }
                .font(MLMFont.muted)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logger.entries) { entry in
                            logRow(entry)
                                .id(entry.id)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .onChange(of: logger.entries.count) { _, _ in
                    // Auto-scroll to bottom
                    if let last = logger.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: AppLogger.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(entry.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.mlmInkMuted)
                .frame(width: 80, alignment: .leading)

            // Level badge
            Text(entry.level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(levelColor(entry.level))
                .frame(width: 36)

            // Source
            if let source = entry.source {
                Text(source)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(width: 70, alignment: .leading)
            }

            // Message
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.mlmInkPrimary)
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
            Text("No log entries")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
            Text("Application events stream here in real time")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
