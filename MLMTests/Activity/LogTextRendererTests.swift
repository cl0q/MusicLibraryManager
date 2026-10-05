import Testing
import Foundation
import AppKit
@testable import MLM

@Suite("LogTextRendererTests")
struct LogTextRendererTests {

    // MARK: - Helpers

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(
        level: AppLogger.Level = .info,
        message: String = "test message",
        source: String? = nil,
        timestamp: Date = fixedDate
    ) -> AppLogger.LogEntry {
        AppLogger.LogEntry(timestamp: timestamp, level: level, message: message, source: source)
    }

    private func makeFingerprint(
        level: LogLevelFilter = .all,
        source: LogSourceFilter = .all,
        search: String = "",
        wrap: Bool = false
    ) -> LogRenderFingerprint {
        LogRenderFingerprint(
            query: LogQuery(level: level, source: source, searchText: search),
            wrapEnabled: wrap
        )
    }

    // MARK: - Behavior 1: nil-source alignment (ragged-column fix)

    @Test
    func sourceCellText_nil_isNonEmpty() {
        let text = LogTextRenderer.sourceCellText(nil)
        #expect(!text.isEmpty, "nil-source cell must emit a non-empty placeholder so the column is visible")
    }

    @Test
    func sourceCellText_nilAndSourced_haveIdenticalCount() {
        let nilCount = LogTextRenderer.sourceCellText(nil).count
        let syncCount = LogTextRenderer.sourceCellText("Sync").count
        #expect(nilCount == syncCount, "nil-source and sourced rows must occupy the same column width to prevent ragged alignment")
        #expect(nilCount > 0, "neither variant should be empty — both must fill the source column")
    }

    // MARK: - Behavior 2: explicit truncation

    @Test
    func sourceCellText_longSource_endsWithEllipsis() {
        let longSource = String(repeating: "A", count: LogColumnLayout.maxSourceCharacters + 5)
        let cell = LogTextRenderer.sourceCellText(longSource)
        #expect(cell.hasSuffix(LogColumnLayout.truncationEllipsis),
                "a source exceeding maxSourceCharacters must end with the visible truncation ellipsis")
    }

    @Test
    func sourceCellText_longSource_doesNotExceedMaxPlusEllipsis() {
        let longSource = String(repeating: "B", count: 50)
        let cell = LogTextRenderer.sourceCellText(longSource)
        let maxLen = LogColumnLayout.maxSourceCharacters + LogColumnLayout.truncationEllipsis.count
        #expect(cell.count <= maxLen,
                "truncated source must not exceed maxSourceCharacters + ellipsis length")
    }

    @Test
    func sourceScan_noPaddingToLength() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Activity
            .deletingLastPathComponent()          // MLMTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("MLM/Views/Activity/LogTextRenderer.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("LogTextRenderer.swift does not exist yet — cannot source-scan for banned API")
            return
        }
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(!src.contains("padding(toLength:"),
                "padding(toLength:) silently truncates and is banned; use tab-stop approach instead")
    }

    // MARK: - Behavior 3: tab stops and column geometry

    @Test
    func tabStopXPositions_areExact() {
        #expect(LogColumnLayout.tabStopXPositions == [104, 156, 268],
                "tab stops align timestamp, level, source and message at the body size")
    }

    @Test
    func messageOriginX_equalsSumOfColumnWidths() {
        let expected = LogColumnLayout.timestampWidth
            + LogColumnLayout.levelWidth
            + LogColumnLayout.sourceWidth
        #expect(LogColumnLayout.messageOriginX == expected,
                "messageOriginX must equal timestampWidth + levelWidth + sourceWidth (84 + 42 + 84 = 210)")
    }

    @Test
    func paragraphStyle_wrapFalse_hasCorrectTabStops() {
        let style = LogTextRenderer.paragraphStyle(wrap: false)
        let xs = style.tabStops.map { $0.location }
        #expect(xs == [104, 156, 268],
                "paragraphStyle tab stops must match LogColumnLayout.tabStopXPositions")
    }

    @Test
    func paragraphStyle_wrapTrue_hasCorrectTabStops() {
        let style = LogTextRenderer.paragraphStyle(wrap: true)
        let xs = style.tabStops.map { $0.location }
        #expect(xs == [104, 156, 268],
                "wrap-true paragraph style must also have tab stops at 84, 126, 210")
    }

    // MARK: - Behavior 4: four columns always emitted

    @Test
    func attributedString_nilSource_hasThreeTabsPerLine() {
        let entry = makeEntry(source: nil)
        let result = LogTextRenderer.attributedString(for: [entry], wrap: false)
        let lines = result.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.isEmpty }
        #expect(!lines.isEmpty, "rendering one entry must produce at least one line")
        let tabCount = lines[0].filter { $0 == "\t" }.count
        #expect(tabCount == 3,
                "every line must have exactly 3 tab separators (timestamp→level→source→message), even when source is nil")
    }

    @Test
    func attributedString_sourcedEntry_hasThreeTabsPerLine() {
        let entry = makeEntry(source: "Sync")
        let result = LogTextRenderer.attributedString(for: [entry], wrap: false)
        let lines = result.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.isEmpty }
        #expect(!lines.isEmpty, "rendering one entry must produce at least one line")
        let tabCount = lines[0].filter { $0 == "\t" }.count
        #expect(tabCount == 3,
                "sourced entry must have exactly 3 tab separators for four-column layout")
    }

    @Test
    func attributedString_nilAndSourced_haveSameTabCount() {
        let nilEntry = makeEntry(message: "hello", source: nil)
        let srcEntry = makeEntry(message: "hello", source: "Sync")
        let nilResult = LogTextRenderer.attributedString(for: [nilEntry], wrap: false)
        let srcResult = LogTextRenderer.attributedString(for: [srcEntry], wrap: false)

        let nilLines = nilResult.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }.filter { !$0.isEmpty }
        let srcLines = srcResult.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }.filter { !$0.isEmpty }

        let nilTabs = nilLines[0].filter { $0 == "\t" }.count
        let srcTabs = srcLines[0].filter { $0 == "\t" }.count
        #expect(nilTabs == srcTabs,
                "nil-source and sourced entries must emit the same number of tabs — this is the column-alignment invariant")
    }

    // MARK: - Behavior 5: newline discipline

    @Test
    func attributedString_singleEntry_noLeadingOrTrailingNewline() {
        let entry = makeEntry()
        let result = LogTextRenderer.attributedString(for: [entry], wrap: false)
        let s = result.string
        #expect(!s.hasPrefix("\n"), "rendered text must not start with a newline")
        #expect(!s.hasSuffix("\n"), "rendered text must not end with a trailing newline")
    }

    @Test
    func attributedString_twoEntries_separatedBySingleNewline() {
        let e1 = makeEntry(message: "first")
        let e2 = makeEntry(message: "second")
        let result = LogTextRenderer.attributedString(for: [e1, e2], wrap: false)
        let s = result.string
        #expect(!s.hasPrefix("\n"), "no leading newline before first entry")
        #expect(!s.hasSuffix("\n"), "no trailing newline after last entry")
        // Exactly one \n between the two entries
        let newlineCount = s.filter { $0 == "\n" }.count
        #expect(newlineCount == 1, "two entries must be separated by exactly one newline")
    }

    // MARK: - Behavior 6: level colors

    @Test
    func levelColor_info_isSecondaryLabel() {
        // W3-ACT: no blue text for an ordinary level (UC-COLOR-04/06); the word carries it.
        #expect(LogTextRenderer.levelColor(.info) == .secondaryLabelColor)
    }

    @Test
    func levelColor_warning_isSystemOrange() {
        #expect(LogTextRenderer.levelColor(.warning) == .systemOrange,
                "warning level must use systemOrange")
    }

    @Test
    func levelColor_error_isSystemRed() {
        #expect(LogTextRenderer.levelColor(.error) == .systemRed,
                "error level must use systemRed")
    }

    @Test
    func levelColor_debug_isTertiaryLabel() {
        #expect(LogTextRenderer.levelColor(.debug) == .tertiaryLabelColor)
    }

    // MARK: - Behavior 7: plan — the stale-render fix

    @Test
    func plan_nilStored_rebuild() {
        let incoming = makeFingerprint()
        let entries = [makeEntry()]
        let result = LogTextRenderer.plan(
            storedFingerprint: nil,
            incomingFingerprint: incoming,
            lastRenderedEntryID: entries.last?.id,
            entries: entries
        )
        #expect(result == .rebuild,
                "nil stored fingerprint means first render — must rebuild")
    }

    @Test
    func plan_fingerprintDiffers_rebuild_evenWhenLastIDPresent() {
        // THIS IS THE EXACT PRODUCTION BUG:
        // The old code checks only whether lastRenderedID is still in entries.
        // When a filter change alters which entries appear but still includes the
        // last rendered ID, the old code returns early (guard !tail.isEmpty) and
        // keeps showing stale unfiltered text on screen.
        // The fix: if the fingerprint differs, ALWAYS rebuild regardless.
        let storedFP = makeFingerprint(level: .all)
        let incomingFP = makeFingerprint(level: .errors)  // filter changed

        let entries = [
            makeEntry(level: .error, message: "err1"),
            makeEntry(level: .error, message: "err2"),
        ]
        let lastID = entries.first!.id  // still present in entries

        let result = LogTextRenderer.plan(
            storedFingerprint: storedFP,
            incomingFingerprint: incomingFP,
            lastRenderedEntryID: lastID,
            entries: entries
        )
        #expect(result == .rebuild,
                "fingerprint change must force rebuild even when lastRenderedEntryID is still in entries — this is the stale-render bug fix")
    }

    @Test
    func plan_fingerprintMatches_nilLastID_rebuild() {
        let fp = makeFingerprint()
        let entries = [makeEntry(), makeEntry()]
        let result = LogTextRenderer.plan(
            storedFingerprint: fp,
            incomingFingerprint: fp,
            lastRenderedEntryID: nil,
            entries: entries
        )
        #expect(result == .rebuild,
                "no last rendered ID means nothing was rendered before — must rebuild")
    }

    @Test
    func plan_fingerprintMatches_newEntriesExist_appendFrom() {
        let fp = makeFingerprint()
        let e1 = makeEntry(message: "first")
        let e2 = makeEntry(message: "second")
        let e3 = makeEntry(message: "third")
        let entries = [e1, e2, e3]
        let lastID = e2.id  // at index 1, entries.count (3) > 1+1 (2)

        let result = LogTextRenderer.plan(
            storedFingerprint: fp,
            incomingFingerprint: fp,
            lastRenderedEntryID: lastID,
            entries: entries
        )
        #expect(result == .appendFrom(index: 2),
                "fingerprint matches and there are new entries after lastID — should append from index 2")
    }

    @Test
    func plan_fingerprintMatches_lastIDisFinal_noChange() {
        let fp = makeFingerprint()
        let e1 = makeEntry(message: "first")
        let e2 = makeEntry(message: "second")
        let entries = [e1, e2]
        let lastID = e2.id  // last entry, no new entries

        let result = LogTextRenderer.plan(
            storedFingerprint: fp,
            incomingFingerprint: fp,
            lastRenderedEntryID: lastID,
            entries: entries
        )
        #expect(result == .noChange,
                "fingerprint matches and last ID is the final entry — nothing to do")
    }

    @Test
    func plan_fingerprintMatches_lastIDAbsent_rebuild() {
        // Simulates Clear followed by new entries — lastRenderedID is gone
        let fp = makeFingerprint()
        let entries = [
            makeEntry(message: "brand new entry"),
        ]
        let staleID = UUID()  // not in entries

        let result = LogTextRenderer.plan(
            storedFingerprint: fp,
            incomingFingerprint: fp,
            lastRenderedEntryID: staleID,
            entries: entries
        )
        #expect(result == .rebuild,
                "fingerprint matches but lastRenderedEntryID is absent from entries (e.g. after Clear) — must rebuild")
    }

    // MARK: - Behavior 8: LogRenderFingerprint is Hashable

    @Test
    func fingerprint_differentWrap_notEqual() {
        let a = makeFingerprint(wrap: false)
        let b = makeFingerprint(wrap: true)
        #expect(a != b, "fingerprints differing only in wrapEnabled must not be equal")
    }

    @Test
    func fingerprint_identical_areEqual() {
        let a = makeFingerprint(level: .warnPlus, search: "hello", wrap: true)
        let b = makeFingerprint(level: .warnPlus, search: "hello", wrap: true)
        #expect(a == b, "identical fingerprints must be equal")
    }

    @Test
    func fingerprint_hashable_canBeUsedInSet() {
        let a = makeFingerprint(wrap: false)
        let b = makeFingerprint(wrap: true)
        var set: Set<LogRenderFingerprint> = [a, b]
        #expect(set.count == 2, "two distinct fingerprints must hash to distinct set entries")
        set.insert(a)
        #expect(set.count == 2, "inserting a duplicate must not increase set count")
    }

    @Test
    func fingerprint_ignoresAutoscrollSoTogglingNeverRebuilds() {
        // Autoscroll changes only scroll behaviour, never the rendered text.
        // If autoscroll were part of the fingerprint, toggling it would force a
        // full O(n) rebuild of up to 5000 entries — a performance defect.
        // The fingerprint must be blind to autoscroll so the view can toggle it
        // without invalidating the rendered buffer.
        let query = LogQuery(level: .all, source: .all, searchText: "")
        let a = LogRenderFingerprint(query: query, wrapEnabled: false)
        let b = LogRenderFingerprint(query: query, wrapEnabled: false)
        #expect(a == b,
                "two fingerprints built at different times with the same query and wrap must be equal — autoscroll is not part of the fingerprint")
    }

    // MARK: - Behavior 9: wrap OFF vs ON differ

    @Test
    func paragraphStyle_wrapOff_differsFromWrapOn() {
        let off = LogTextRenderer.paragraphStyle(wrap: false)
        let on = LogTextRenderer.paragraphStyle(wrap: true)
        #expect(off != on,
                "wrap-off and wrap-on paragraph styles must differ (line break mode or width mode)")
    }
}
