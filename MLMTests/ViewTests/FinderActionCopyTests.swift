import Testing
import Foundation

/// Source-scan contract: "Show in Finder" is the only label for Finder actions
/// (UI-GROUNDTRUTH §5.6). Scans the string literals of every Swift file under `MLM/`;
/// comment lines are skipped so doc comments don't count as UI copy.
@Suite("Finder action copy contract")
struct FinderActionCopyTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private var swiftSources: [URL] {
        let appRoot = projectRoot.appendingPathComponent("MLM")
        let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    /// String literals per line, ignoring comment-only lines.
    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range(at: 1), in: line) { literals.append(String(line[r])) }
            }
        }
        return literals
    }

    @Test func scansAppSources() {
        #expect(swiftSources.count > 100)
    }

    @Test func noLegacyFinderLabels() throws {
        let banned = ["Reveal in Finder", "Reveal In Finder", "In Finder anzeigen"]
        for file in swiftSources {
            let literals = try stringLiterals(in: String(contentsOf: file, encoding: .utf8))
            for literal in literals {
                for term in banned {
                    #expect(!literal.contains(term),
                            "\(file.lastPathComponent): \"\(literal)\" — use \"Show in Finder\"")
                }
            }
        }
    }

    /// "Reveal in …" is only allowed where nothing opens in Finder (UI-GROUNDTRUTH §2.2).
    @Test func noOtherRevealLabels() throws {
        let allowed: Set<String> = ["Reveal in Grid"]
        for file in swiftSources {
            for literal in try stringLiterals(in: String(contentsOf: file, encoding: .utf8))
            where literal.hasPrefix("Reveal in ") && !allowed.contains(literal) {
                Issue.record("\(file.lastPathComponent): \"\(literal)\" — Finder actions are \"Show in Finder\"")
            }
        }
    }

    @Test func formerViolationsUseShowInFinder() throws {
        for path in [
            // W3-SET: the Settings tabs share one `Show in Finder` button (SettingsRows).
            "MLM/Views/Settings/SettingsRows.swift",
            "MLM/Views/TrackList/TrackMenu.swift",
            "MLM/Views/Sync/SyncFailedDisclosure.swift",
            "MLM/Views/Sync/SyncProfileDetailView.swift",
        ] {
            let src = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(src.contains("\"Show in Finder\""), "\(path) lost its Show in Finder label")
        }
    }

    @Test func librarySetupUsesActivateFileViewer() throws {
        let src = try String(
            contentsOf: projectRoot.appendingPathComponent("MLM/Views/Settings/SettingsRows.swift"),
            encoding: .utf8)
        #expect(src.contains("activateFileViewerSelecting"))
        #expect(!src.contains("selectFile(nil"))
    }
}
