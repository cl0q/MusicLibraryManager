import Testing
import Foundation

/// Source-scan tests verifying the Activity Panel redesign contract (Module 5).
///
/// These tests read the three view files as text and assert on their structure,
/// mirroring the pattern established in `ShellLayoutTests.swift`.
///
/// Covers every numbered item in CONTRACTS.md Module 5 (1–17).
@Suite("ActivityPanelStructureTests")
struct ActivityPanelStructureTests {

    // MARK: - Helpers

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // Activity
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Item 1: Vanishing-operation filter removed

    @Test
    func operationsTab_noSyncFilter() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("$0.type != .sync"),
                "OperationsTab must not filter out .sync operations — that filter is the vanishing-operation bug")
    }

    // MARK: - Item 2: Obsolete row types removed (one test per name)

    @Test
    func operationsTab_noDownloadStatusRow() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("struct DownloadStatusRow"),
                "DownloadStatusRow must be removed — Module 2 provides a single canonical row")
    }

    @Test
    func operationsTab_noSyncStatusRow() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("struct SyncStatusRow"),
                "SyncStatusRow must be removed — Module 2 provides a single canonical row")
    }

    @Test
    func operationsTab_noPerformanceQueueStatusRow() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("struct PerformanceQueueStatusRow"),
                "PerformanceQueueStatusRow must be removed — Module 2 provides a single canonical row")
    }

    @Test
    func operationsTab_noDownloadItemRow() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("struct DownloadItemRow"),
                "DownloadItemRow must be removed — Module 2 provides a single canonical row")
    }

    @Test
    func operationsTab_noPersistedDownloadFailureRow() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("struct PersistedDownloadFailureRow"),
                "PersistedDownloadFailureRow must be removed — Module 2 provides a single canonical row")
    }

    // MARK: - Item 3: Hardcoded chip literals removed from LogsTab

    @Test
    func logsTab_noTranscodeChip() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(!src.contains("\"Transcode\""),
                "LogsTab must not contain hardcoded \"Transcode\" chip — sources are derived via LogFeed.availableSources")
    }

    @Test
    func logsTab_noPerfChip() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(!src.contains("\"perf\""),
                "LogsTab must not contain hardcoded \"perf\" chip — sources are derived via LogFeed.availableSources")
    }

    @Test
    func logsTab_noBootChip() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(!src.contains("\"boot\""),
                "LogsTab must not contain hardcoded \"boot\" chip — sources are derived via LogFeed.availableSources")
    }

    // MARK: - Item 4: filteredEntries computed property removed

    @Test
    func logsTab_noFilteredEntriesComputedProperty() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(!src.contains("var filteredEntries"),
                "LogsTab must not contain a computed property named filteredEntries — replaced by a cached @State driven by LogFeed.shouldRequery")
    }

    // MARK: - Item 5: No hiddenTitleBar in ActivityPanel

    @Test
    func activityPanel_noHiddenTitleBar() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(!src.contains(".hiddenTitleBar"),
                "ActivityPanel must not contain .hiddenTitleBar — use the native macOS toolbar")
    }

    // MARK: - Item 6: No hardcoded hex colors in any of the three files

    @Test
    func activityPanel_noHardcodedColors() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(!src.contains("Color(red:"),
                "ActivityPanel must not use Color(red:) — use existing tokens from MLM/Theme/Colors.swift")
    }

    @Test
    func operationsTab_noHardcodedColors() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("Color(red:"),
                "OperationsTab must not use Color(red:) — use existing tokens from MLM/Theme/Colors.swift")
    }

    @Test
    func logsTab_noHardcodedColors() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(!src.contains("Color(red:"),
                "LogsTab must not use Color(red:) — use existing tokens from MLM/Theme/Colors.swift")
    }

    // MARK: - Item 7: ActivityPanel keeps parameterless initializer

    @Test
    func activityPanel_parameterlessInit() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("struct ActivityPanel: View"),
                "ActivityPanel must declare struct ActivityPanel: View")
        // ContentView.swift is DIRTY with the user's uncommitted work and must not be edited,
        // so ActivityPanel() must remain callable with no arguments.
        #expect(!src.contains("init("),
                "ActivityPanel must not declare a custom init — ContentView.swift calls ActivityPanel() and that file is DIRTY with uncommitted work")
    }

    // MARK: - Item 8: @AppStorage keys

    @Test
    func activityPanel_appStorage_expanded() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("\"activity.panel.expanded\""),
                "ActivityPanel must persist expanded state with @AppStorage key \"activity.panel.expanded\"")
    }

    @Test
    func activityPanel_appStorage_height() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("\"activity.panel.height\""),
                "ActivityPanel must persist panel height with @AppStorage key \"activity.panel.height\"")
    }

    @Test
    func activityPanel_appStorage_selectedTab() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("\"activity.selectedTab\""),
                "ActivityPanel must persist selected tab with @AppStorage key \"activity.selectedTab\"")
    }

    // MARK: - Item 9: Height clamp + dedicated resize handle

    @Test
    func activityPanel_heightClamp150to700() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("150") && src.contains("700"),
                "ActivityPanel must preserve the 150...700 height clamp")
    }

    @Test
    func activityPanel_dedicatedResizeHandle() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        // The resize handle must NOT be a Color.clear overlay stacked over the collapse Button
        // (gesture conflict). Assert a dedicated named handle view exists.
        #expect(src.contains("ResizeHandle") || src.contains("resizeHandle"),
                "ActivityPanel must have a dedicated named resize handle view, not a Color.clear overlay over the collapse Button")
    }

    // MARK: - Item 10: Accessibility identifiers (grouped logically)

    // Panel chrome identifiers
    @Test
    func accessibilityIDs_panelChrome() throws {
        let panelSrc = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        let opsSrc = try readSource("MLM/Views/Activity/OperationsTab.swift")
        let logsSrc = try readSource("MLM/Views/Activity/LogsTab.swift")
        let all = panelSrc + opsSrc + logsSrc

        let panelChromeIDs = [
            "activity_panel",
            "activity_header",
            "activity_header_summary",
            "activity_header_chevron",
            "activity_tab_picker",
        ]
        for id in panelChromeIDs {
            #expect(all.contains("\"\(id)\""),
                    "Accessibility identifier \"\(id)\" must appear in the view layer (panel chrome group)")
        }
    }

    // Operations tab identifiers
    @Test
    func accessibilityIDs_operationsSections() throws {
        let opsSrc = try readSource("MLM/Views/Activity/OperationsTab.swift")

        let sectionIDs = [
            "operations_empty_state",
            "operations_section_active",
            "operations_section_attention",
            "operations_section_recent",
            "operations_recent_clear_button",
            "operations_recent_cap_notice",
            "operation_analysis_clear_button",
        ]
        for id in sectionIDs {
            #expect(opsSrc.contains("\"\(id)\""),
                    "Accessibility identifier \"\(id)\" must appear in OperationsTab.swift")
        }
    }

    @Test
    func accessibilityIDs_operationsRowControls() throws {
        let opsSrc = try readSource("MLM/Views/Activity/OperationsTab.swift")

        let rowIDs = [
            "operation_cancel_button",
            "operation_retry_button",
            "operation_progress",
            "operation_status_badge",
            "operation_download_expansion",
            "operation_download_item",
        ]
        for id in rowIDs {
            #expect(opsSrc.contains("\"\(id)\""),
                    "Accessibility identifier \"\(id)\" must appear in OperationsTab.swift (row controls group)")
        }
    }

    // Logs tab identifiers
    @Test
    func accessibilityIDs_logsTab() throws {
        let logsSrc = try readSource("MLM/Views/Activity/LogsTab.swift")

        let logsIDs = [
            "logs_toolbar",
            "logs_level_filter",
            "logs_source_filter",
            "logs_search_field",
            "logs_search_clear_button",
            "logs_pause_toggle",
            "logs_autoscroll_toggle",
            "logs_wrap_toggle",
            "logs_clear_button",
            "logs_reveal_button",
            "logs_text_view",
            "logs_empty_state",
        ]
        for id in logsIDs {
            #expect(logsSrc.contains("\"\(id)\""),
                    "Accessibility identifier \"\(id)\" must appear in LogsTab.swift")
        }
    }

    // Stable "operation_row_" prefix (Module 2 contract)
    @Test
    func accessibilityIDs_operationRowPrefix() throws {
        let opsSrc = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(opsSrc.contains("\"operation_row_\""),
                "OperationsTab must use the stable \"operation_row_\" prefix for parameterized row identifiers")
    }

    // MARK: - Item 11: Logs toolbar is ONE row with three toggles

    @Test
    func logsTab_toolbarAppearsOnce() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        let occurrences = src.components(separatedBy: "\"logs_toolbar\"").count - 1
        #expect(occurrences == 1,
                "LogsTab must contain \"logs_toolbar\" exactly once — toolbar is ONE row, got \(occurrences)")
    }

    @Test
    func logsTab_toolbarHasThreeToggles() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        #expect(src.contains("\"logs_pause_toggle\""),
                "Logs toolbar must contain logs_pause_toggle")
        #expect(src.contains("\"logs_autoscroll_toggle\""),
                "Logs toolbar must contain logs_autoscroll_toggle")
        #expect(src.contains("\"logs_wrap_toggle\""),
                "Logs toolbar must contain logs_wrap_toggle")
    }

    // MARK: - Item 12: clearAnalysisQueue behind confirmation alert

    // Approximation: assert .alert( is present in OperationsTab and that clearQueue()
    // appears at most once and .alert( appears before it in the file. This does NOT
    // prove the alert guards clearQueue — only that both constructs exist in the
    // expected order. A stronger check would require AST analysis.
    @Test
    func operationsTab_alertPresent() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(src.contains(".alert("),
                "OperationsTab must contain .alert( for the destructive-queue-clear confirmation")
    }

    @Test
    func operationsTab_clearQueueBehindAlert() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        let clearCount = src.components(separatedBy: "clearQueue()").count - 1
        #expect(clearCount <= 1,
                "clearQueue() should appear at most once — it must be behind a confirmation alert, not a direct Button action")

        if clearCount == 1,
           let alertIdx = src.range(of: ".alert(")?.lowerBound,
           let clearIdx = src.range(of: "clearQueue()")?.lowerBound {
            #expect(alertIdx < clearIdx,
                    ".alert( must appear before clearQueue() — the alert confirms the destructive action")
        }
    }

    // UI-008 regression lock: the ROW action renderer must wire .clearAnalysisQueue
    // to the confirmation-alert trigger, not return EmptyView. The feed emits
    // .clearAnalysisQueue only as a row action (rowForQueueSource), so the live
    // route is actionButton → showClearQueueAlert → .alert → clearQueue(). Scoped
    // to the actionButton function body to prove the row case specifically.
    @Test
    func operationsTab_rowClearAnalysisQueueOpensAlert() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")

        // Isolate the row actionButton(_ action:...) function body.
        let fnStart = try #require(src.range(of: "func actionButton(")?.lowerBound,
                "OperationsTab must define a row actionButton(_ action:) renderer")
        let tail = src[fnStart...]
        let fnEnd = tail.range(of: "\n    private func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<fnEnd])

        // Within that body, the .clearAnalysisQueue case must set the alert trigger
        // and must NOT be an EmptyView.
        let caseStart = try #require(body.range(of: "case .clearAnalysisQueue:")?.lowerBound,
                "actionButton must handle .clearAnalysisQueue (UI-008 row route)")
        let caseTail = body[caseStart...]
        let caseEnd = caseTail.range(of: "\n        case ")?.lowerBound ?? caseTail.endIndex
        let caseBody = String(caseTail[..<caseEnd])

        #expect(caseBody.contains("showClearQueueAlert = true"),
                "The .clearAnalysisQueue ROW action must set showClearQueueAlert = true to open the confirmation alert (UI-008)")
        #expect(!caseBody.contains("EmptyView()"),
                "The .clearAnalysisQueue ROW action must render a control, not EmptyView (UI-008 dead-action regression)")
    }

    // MARK: - Item 13: 250 ms search debounce

    @Test
    func logsTab_searchDebounce250ms() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        // Accept either .task(id: with Task.sleep(250_000_000) or nanoseconds: 250
        let hasNanosecondDebounce = src.contains("250_000_000") || src.contains("250000000")
        let hasTaskIDDebounce = src.contains(".task(id:") && (hasNanosecondDebounce || src.contains("nanoseconds: 250"))
        let hasDebounce = hasNanosecondDebounce || hasTaskIDDebounce
        #expect(hasDebounce,
                "LogsTab must debounce search at 250 ms — accept .task(id:) with Task.sleep(250_000_000) or nanoseconds: 250")
    }

    // MARK: - Item 14: accessibilityReduceMotion gates animation

    @Test
    func activityPanel_reduceMotionGatesAnimation() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        #expect(src.contains("accessibilityReduceMotion"),
                "ActivityPanel must read accessibilityReduceMotion and gate animation accordingly")
    }

    // MARK: - Item 15: Escape collapses the panel

    @Test
    func activityPanel_escapeCollapsesPanel() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        let hasEscapeShortcut = src.contains(".keyboardShortcut(.escape")
            || src.contains(".keyboardShortcut(.init(.escape")
            || src.contains("keyEquivalent: .escape")
        #expect(hasEscapeShortcut,
                "ActivityPanel must collapse on Escape — assert .keyboardShortcut(.escape) or equivalent handler")
    }

    // MARK: - Item 16: ProgressView and status badge identifiers

    @Test
    func operationsTab_progressViewCarriesIdentifier() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        // Every ProgressView in the operations row must carry operation_progress.
        // Approximation: the file must contain both "ProgressView" and "operation_progress".
        #expect(src.contains("ProgressView") && src.contains("\"operation_progress\""),
                "OperationsTab: every ProgressView in the operations row must carry operation_progress identifier")
    }

    @Test
    func operationsTab_statusBadgeCarriesIdentifier() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        // Status capsules must carry operation_status_badge.
        #expect(src.contains("Capsule") && src.contains("\"operation_status_badge\""),
                "OperationsTab: status capsules must carry operation_status_badge identifier")
    }

    // MARK: - Item 17: No print( statements in the three view files

    // Item 17: No print( debug statements.
    // Uses a word-boundary regex so that legitimate identifiers ending in "print"
    // followed by "(" — e.g. LogRenderFingerprint( — are not falsely flagged.
    // A genuine print() call is always preceded by start-of-line, whitespace,
    // `{`, or `;` — never by an identifier character.
    private static let printCallPattern = "(^|[^A-Za-z0-9_])print\\("

    @Test
    func activityPanel_noPrintStatements() throws {
        let src = try readSource("MLM/Views/Activity/ActivityPanel.swift")
        let match = src.range(of: Self.printCallPattern, options: .regularExpression)
        #expect(match == nil,
                "ActivityPanel must not contain print() debug statements — use AppLogger for diagnostics")
    }

    @Test
    func operationsTab_noPrintStatements() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        let match = src.range(of: Self.printCallPattern, options: .regularExpression)
        #expect(match == nil,
                "OperationsTab must not contain print() debug statements — use AppLogger for diagnostics")
    }

    @Test
    func logsTab_noPrintStatements() throws {
        let src = try readSource("MLM/Views/Activity/LogsTab.swift")
        let match = src.range(of: Self.printCallPattern, options: .regularExpression)
        #expect(match == nil,
                "LogsTab must not contain print() debug statements — use AppLogger for diagnostics")
    }

    // Regression guard: the word-boundary regex must NOT match "LogRenderFingerprint("
    // because the substring "print(" spans the type name and the init's opening paren.
    // This makes the boundary behavior an explicit invariant, not an accident.
    @Test
    func printDetection_doesNotMatchLogRenderFingerprint() {
        let probe = "LogRenderFingerprint(query: query, wrapEnabled: true)"
        let match = probe.range(of: Self.printCallPattern, options: .regularExpression)
        #expect(match == nil,
                "Print-detection regex must not match LogRenderFingerprint( — the 'print(' substring spans the type name and init paren")
    }

    // MARK: - A11.3: View wiring — disabled-button branch removed, real retry wired

    // A11.2/A11.3: Non-retryable failures render no button at all rather than a
    // permanently-disabled one. The old tooltip string must be gone.
    @Test
    func operationsTab_noDisabledRetryTooltip() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(!src.contains("No retry action available for this operation"),
                "OperationsTab must not contain the disabled-retry tooltip — A11.2/A11.3: non-retryable failures render no button at all")
    }

    // A11.3: .retry(operationID:) must wire to ActivityViewModel.retryOperation(id:),
    // not to an ad-hoc path. The presence of `retryOperation(id:` proves the wiring.
    @Test
    func operationsTab_wiresRetryOperation() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(src.contains("retryOperation(id:"),
                "OperationsTab must call retryOperation(id:) — A11.3 wires .retry(operationID:) to ActivityViewModel.retryOperation")
    }

    // A11.3: The single download retry path must survive.
    @Test
    func operationsTab_retainsRetryAllFailed() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        #expect(src.contains("retryAllFailed(trackIds:"),
                "OperationsTab must still contain retryAllFailed(trackIds: — the single download retry path must survive A11.3")
    }

    // A11.3: The old overlapping retryFailed() path (which caused double-downloads)
    // must NOT reappear. Uses a word-boundary regex so it does not accidentally match
    // retryAllFailed(trackIds:.
    // Pattern: (^|[^A-Za-z])retryFailed\(\) — a real call is preceded by start-of-line,
    // whitespace, or a non-alpha character, never by an identifier character.
    private static let retryFailedPattern = "(^|[^A-Za-z])retryFailed\\(\\)"

    @Test
    func operationsTab_noOverlappingRetryFailed() throws {
        let src = try readSource("MLM/Views/Activity/OperationsTab.swift")
        let match = src.range(of: Self.retryFailedPattern, options: .regularExpression)
        #expect(match == nil,
                "OperationsTab must not contain retryFailed() — the old overlapping retry path that caused double-downloads (A11.3)")
    }

    // Regression guard: the retryFailed() word-boundary regex must NOT match
    // "retryAllFailed(trackIds:" — verify the pattern is safe.
    @Test
    func retryFailedDetection_doesNotMatchRetryAllFailed() {
        let probe = "await container.downloadViewModel?.retryAllFailed(trackIds: op.retryTrackIds)"
        let match = probe.range(of: Self.retryFailedPattern, options: .regularExpression)
        #expect(match == nil,
                "retryFailed() regex must not match retryAllFailed(trackIds: — word-boundary guard")
    }
}
