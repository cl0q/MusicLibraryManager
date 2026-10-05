import Testing
import Foundation
@testable import MLM

/// W1-2 review S1 / nit: which keys a menu command hands back (UC-KEY-10/34/38).
@Suite("Key equivalents typing and sheets keep (W1-2 review)")
struct KeyEquivalentDecisionTests {
    private let lineEnd: String?? = .some("moveToEndOfLine:")
    private let cancel: String?? = .some("cancelOperation:")

    @Test func mouseChoicesAlwaysRun() {
        #expect(KeyEquivalentDecision.decide(isKeyPress: false, editingText: true, sheetIsUp: true,
                                             textMeaning: lineEnd, sheetKeepsKey: true) == .runCommand)
    }

    @Test func typingKeepsItsKeys() {
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: true, sheetIsUp: false,
                                             textMeaning: lineEnd, sheetKeepsKey: false) == .handToText("moveToEndOfLine:"))
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: true, sheetIsUp: false,
                                             textMeaning: .some(nil), sheetKeepsKey: false) == .handToText(nil))
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: false, sheetIsUp: false,
                                             textMeaning: lineEnd, sheetKeepsKey: false) == .runCommand)
    }

    @Test func stopKeyNeverStopsPlaybackWhileTypingOrInASheet() {
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: true, sheetIsUp: false,
                                             textMeaning: cancel, sheetKeepsKey: true) == .handToText("cancelOperation:"))
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: false, sheetIsUp: true,
                                             textMeaning: cancel, sheetKeepsKey: true) == .handToSheet,
                "a sheet without a Cancel button still keeps ⌘.")
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: true, sheetIsUp: true,
                                             textMeaning: cancel, sheetKeepsKey: true) == .handToSheet)
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: false, sheetIsUp: false,
                                             textMeaning: cancel, sheetKeepsKey: true) == .runCommand)
    }

    @Test func keysWithoutATextMeaningRunWhileTyping() {
        #expect(KeyEquivalentDecision.decide(isKeyPress: true, editingText: true, sheetIsUp: false,
                                             textMeaning: nil, sheetKeepsKey: false) == .runCommand)
    }
}
