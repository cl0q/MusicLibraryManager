import Foundation
import Testing
@testable import MLM

/// The reusable scope bar's rules (W2-B, UC-SCOPE-01…05): which scopes show, which one is
/// chosen, how counts read on screen and to VoiceOver.
@Suite("ScopeBarRulesTests")
struct ScopeBarRulesTests {
    private enum Scope: String, CaseIterable { case all, failed, missing }

    private func items(failed: Int?, missing: Int? = 3, hideFailed: Bool = false) -> [ScopeBarItem<Scope>] {
        [
            ScopeBarItem(id: .all, title: "All", count: 12_935),
            ScopeBarItem(id: .failed, title: "Download failed", count: failed, hidesWhenEmpty: hideFailed),
            ScopeBarItem(id: .missing, title: "File missing", count: missing),
        ]
    }

    @Test func zeroCountScopesShowUnlessTheyHideWhenEmpty() {
        // All Tracks: every scope shows, zero included.
        #expect(ScopeBarRules.visibleItems(items(failed: 0), selection: .all).map(\.id) == [.all, .failed, .missing])
        // Playlist detail style: `Download failed` only while something failed…
        #expect(ScopeBarRules.visibleItems(items(failed: 0, hideFailed: true), selection: .all).map(\.id) == [.all, .missing])
        #expect(ScopeBarRules.visibleItems(items(failed: 2, hideFailed: true), selection: .all).map(\.id) == [.all, .failed, .missing])
        // …and while it is the chosen scope, so the bar never loses the selection.
        #expect(ScopeBarRules.visibleItems(items(failed: 0, hideFailed: true), selection: .failed).map(\.id) == [.all, .failed, .missing])
        // Unknown counts (first load) never hide a scope.
        #expect(ScopeBarRules.visibleItems(items(failed: nil, hideFailed: false), selection: .all).count == 3)
    }

    @Test func aStoredScopeThatNoLongerExistsFallsBackToTheFirst() {
        let list = items(failed: 1)
        #expect(ScopeBarRules.resolvedSelection(.missing, in: list) == .missing)
        #expect(ScopeBarRules.resolvedSelection(.missing, in: Array(list.prefix(2))) == .all)
        #expect(ScopeBarRules.resolvedSelection(Scope.all, in: [ScopeBarItem<Scope>]()) == nil)
    }

    @Test func countsUseThousandsSeparators() {
        #expect(ScopeBarRules.countText(12_935) == 12_935.formatted(.number))
        #expect(ScopeBarRules.countText(0) == "0")
        #expect(ScopeBarRules.countText(nil) == nil)
    }

    @Test func voiceOverLabelIncludesTheCountAndItsNoun() {
        #expect(ScopeBarRules.accessibilityLabel(title: "Download failed", count: 1, noun: .tracks) == "Download failed, 1 track")
        #expect(ScopeBarRules.accessibilityLabel(title: "All", count: 12_935, noun: .tracks)
            == "All, \(12_935.formatted(.number)) tracks")
        #expect(ScopeBarRules.accessibilityLabel(title: "Local", count: nil, noun: .tracks) == "Local")
        #expect(ScopeBarRules.accessibilityLabel(title: "Complete", count: 0, noun: .albums) == "Complete, 0 albums")
    }
}
