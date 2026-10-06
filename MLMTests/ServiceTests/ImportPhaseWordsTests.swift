import Foundation
import Testing
@testable import MLM

/// W5-1a G36: the import phases that reach the Activity row use the app's words (UC-COPY-05,
/// UC-GLOSS-03): an ellipsis character, no "database".
@Suite("ImportPhaseWordsTests")
struct ImportPhaseWordsTests {
    @Test func phasesUseTheGlossaryWords() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MLM/Services/Import/ImportService.swift"), encoding: .utf8)
        for phase in ["Scanning…", "Reading tags…", "Adding to the library…", "Finished"] {
            #expect(text.contains("phase: \"\(phase)\""), Comment(rawValue: phase))
        }
        for old in ["Extracting metadata", "Saving to", "database...", "\"Complete\"", "Scanning..."] {
            #expect(!text.contains("phase: \"\(old)") && !text.contains(old), Comment(rawValue: old))
        }
    }
}
