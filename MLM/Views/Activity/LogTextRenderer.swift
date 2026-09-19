import Foundation
import AppKit

// MARK: - Column layout

enum LogColumnLayout {
    static let timestampWidth: CGFloat = 84
    static let levelWidth: CGFloat = 42
    static let sourceWidth: CGFloat = 84
    static let messageOriginX: CGFloat = 210 // 84 + 42 + 84
    static let tabStopXPositions: [CGFloat] = [84, 126, 210]
    static let maxSourceCharacters: Int = 12
    static let truncationEllipsis: String = "…"
}

// MARK: - Render fingerprint

// Autoscroll is intentionally excluded: it affects scrolling only, never
// rendered text. Including it would force an O(n) rebuild on every toggle.
struct LogRenderFingerprint: Hashable, Equatable {
    let query: LogQuery
    let wrapEnabled: Bool
}

// MARK: - Append plan

enum LogAppendPlan: Equatable {
    case rebuild
    case appendFrom(index: Int)
    case noChange
}

// MARK: - Renderer

enum LogTextRenderer {

    // MARK: source cell

    /// Always returns a fixed-width cell so nil-source rows align with sourced rows.
    static func sourceCellText(_ source: String?) -> String {
        let raw: String
        if let source = source {
            raw = source
        } else {
            raw = ""
        }

        let maxChars = LogColumnLayout.maxSourceCharacters
        let ellipsis = LogColumnLayout.truncationEllipsis

        let display: String
        if raw.count > maxChars {
            display = String(raw.prefix(maxChars)) + ellipsis
        } else {
            display = raw
        }

        // Pad with spaces to fill the column so every row is the same width.
        let targetWidth = maxChars + ellipsis.count
        if display.count < targetWidth {
            return display + String(repeating: " ", count: targetWidth - display.count)
        }
        return display
    }

    // MARK: paragraph style

    static func paragraphStyle(wrap: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let stops = LogColumnLayout.tabStopXPositions
        style.tabStops = stops.map { NSTextTab(textAlignment: .left, location: $0) }
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        if wrap {
            style.lineBreakMode = .byWordWrapping
        } else {
            style.lineBreakMode = .byClipping
        }
        return style
    }

    // MARK: level color

    static func levelColor(_ level: AppLogger.Level) -> NSColor {
        switch level {
        case .info:    return .systemBlue
        case .warning: return .systemOrange
        case .error:   return .systemRed
        case .debug:   return .systemGray
        }
    }

    // MARK: attributed string

    static func attributedString(for entries: [AppLogger.LogEntry], wrap: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = paragraphStyle(wrap: wrap)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let monoMedium = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let line = buildLine(entry: entry, para: para, mono: mono, monoBold: monoBold, monoMedium: monoMedium)
            result.append(line)
        }
        return result
    }

    // MARK: plan

    static func plan(
        storedFingerprint: LogRenderFingerprint?,
        incomingFingerprint: LogRenderFingerprint,
        lastRenderedEntryID: UUID?,
        entries: [AppLogger.LogEntry]
    ) -> LogAppendPlan {
        guard let stored = storedFingerprint else { return .rebuild }
        guard stored == incomingFingerprint else { return .rebuild }

        guard let lastID = lastRenderedEntryID else { return .rebuild }

        guard let lastIndex = entries.firstIndex(where: { $0.id == lastID }) else {
            return .rebuild
        }

        let nextIndex = lastIndex + 1
        if nextIndex < entries.count {
            return .appendFrom(index: nextIndex)
        }
        return .noChange
    }

    // MARK: - Private helpers

    private static func buildLine(
        entry: AppLogger.LogEntry,
        para: NSParagraphStyle,
        mono: NSFont,
        monoBold: NSFont,
        monoMedium: NSFont
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()

        // Timestamp column
        let tsAttrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]
        line.append(NSAttributedString(string: entry.formattedTime + "\t", attributes: tsAttrs))

        // Level column
        let levelAttrs: [NSAttributedString.Key: Any] = [
            .font: monoBold,
            .foregroundColor: levelColor(entry.level),
            .paragraphStyle: para
        ]
        line.append(NSAttributedString(string: entry.level.rawValue + "\t", attributes: levelAttrs))

        // Source column — always emitted, even for nil source (ragged-column fix)
        let sourceAttrs: [NSAttributedString.Key: Any] = [
            .font: monoMedium,
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: para
        ]
        line.append(NSAttributedString(string: sourceCellText(entry.source) + "\t", attributes: sourceAttrs))

        // Message column
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]
        line.append(NSAttributedString(string: entry.message, attributes: msgAttrs))

        return line
    }
}
