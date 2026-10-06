import Testing
import Foundation
@testable import MLM

/// Source-scan contract for the launch surfaces (W3-LAUNCH, `launch.html`, UC-STATE §15.1):
/// the approved words, Title Case buttons, no banned or German strings, no hand-rolled open
/// panels, no `mlm*` tokens, routing from `ContentView`. Replaces the A3 suites of
/// `LibraryLaunchStateView` and `LibraryAdoptionSheet` (both views removed).
@Suite("Launch views contract (W3-LAUNCH)")
struct LaunchViewsContractTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var launchFiles: [String] {
        let directory = projectRoot.appendingPathComponent("MLM/Views/Launch")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().map { "MLM/Views/Launch/\($0)" }
    }

    private var launchSource: String {
        get throws { try launchFiles.map(source).joined(separator: "\n") }
    }

    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range(at: 1), in: line) { literals.append(String(line[r])) }
            }
        }
        return literals
    }

    /// `Saved as “\(name)”.` → `Saved as “”.` (balanced parentheses).
    static func withoutInterpolations(_ literal: String) -> String {
        var result = ""
        var characters = Array(literal)[...]
        while let character = characters.popFirst() {
            if character == "\\", characters.first == "(" {
                characters.removeFirst()
                var depth = 1
                while depth > 0, let next = characters.popFirst() {
                    if next == "(" { depth += 1 } else if next == ")" { depth -= 1 }
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    @Test func theLaunchFilesExist() {
        #expect(launchFiles.count == 9, "\(launchFiles)")
        for gone in ["LibraryLaunchStateView", "FirstRunWizard", "LibraryAdoptionSheet", "NewLibrarySheet"] {
            #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("MLM/Views/Shared/\(gone).swift").path))
        }
    }

    @Test func usesTheApprovedWords() throws {
        let src = try launchSource + source("MLM/Services/Library/LibraryLaunchCoordinator.swift")
            + source("MLM/Services/Library/LibraryPickerRows.swift") + source("MLM/Services/Library/LibraryOpenPhase.swift")
        let approved = [
            // V-PICKER
            "Choose a library", "MLM opens one library at a time. Switching later relaunches MLM.",
            "can’t be opened", "The reason is shown on its row. Fix it there, or open another library.",
            "New Library…", "Open Other…", "Open the last library at launch",
            "Drop a library file (.mlibm) here to open it", "No libraries yet",
            "Create a library, or open a library file you already have. You can also drop a library file here.",
            "Not found", "Not connected — on “", "Try Again", "Locate…", "Remove from List", "Set Up…",
            "Show in Finder", "Copy Path", "(needs setup)", "Checked just now — “",
            // V-LAUNCH-LOADING
            "Opening “", "Reading the library…", "Backing up before update…", "Finishing library file setup…",
            // V-LAUNCH-FAILED / -INVALID
            "couldn’t be opened", "Choose Another Library", "Restore from Backup…", "Show Logs", "Details",
            "isn’t a valid library file",
            "It doesn’t contain a library database. The file may be incomplete or damaged. MLM didn’t change it.",
            "It was made by a newer version of MLM. Update MLM to open it. MLM didn’t change the file.",
            "The library database couldn’t be read. Your music files are not affected, and MLM didn’t change the library file.",
            // S-ADOPT
            "Set up your library file",
            "MLM now keeps your library — tracks, playlists, settings and playlist covers — in a single library file that you can move and back up as one item. MLM backs up first, then copies your library into the new file. Audio files are not moved.",
            "Not Now", "Create Library File", "Backing up…", "Creating library file…", "Checking…",
            "This can’t be interrupted. It usually takes under a minute.",
            "The library file couldn’t be created. Your library was not changed.", "Done",
            // S-NEWLIB / V-SETUP
            "New Library", "A library keeps its own tracks, playlists and settings. Audio files stay where they are.",
            "MLM Libraries folder (default)", "Choose…", "Create",
            "Step ", "Create your library", "Create Library", "Where is your music?", "Choose Folder…",
            "Drop your music folder here", "Set Up Later", "Scan and Import", "Scan When Connected",
            "Continue in Background", "Stop", "is ready",
            "MLM will create folders like “Downloads (SoundCloud)” inside this folder when you import from sources. Your existing files are not moved.",
            // Alerts
            "Switch to “", "MLM quits and reopens with “", "Switch and Relaunch", "Quit MLM?",
            "is a copy of", "To open it, MLM makes the copy a separate library.", "Open as Separate Library",
            "Choose Another Location…", "Restore and Relaunch",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
    }

    @Test func noBannedGermanOrSentenceCaseButtons() throws {
        // The user-visible text: string interpolations (code) are dropped first.
        let literals = try stringLiterals(in: try launchSource).map(Self.withoutInterpolations)
        let banned = [
            "Package", "package", "Bundle", "Database file", "Reveal", "Failed to Initialize", "Loading Library",
            "No library open", "Show In Finder", "Bibliothek", "Mediathek", "Abbrechen", "Erstellen", "Öffnen",
            "Später", "...",
        ]
        // Sentence-case button titles of the A3 placeholders (UC-COPY-02: Title Case now).
        let oldButtons: Set<String> = ["Not now", "Try again", "Create library file", "Open as separate library", "OK…"]
        for literal in literals {
            for term in banned {
                #expect(!literal.contains(term), "banned term \(term) in \"\(literal)\"")
            }
            #expect(!oldButtons.contains(literal), "sentence-case button \"\(literal)\"")
            #expect(!literal.contains("\""), "straight quotes in \"\(literal)\"")
            #expect(!literal.unicodeScalars.contains { $0.properties.isEmojiPresentation })
        }
    }

    @Test func systemControlsOnlyNoTokensNoHandRolledPanels() throws {
        let src = try launchSource + source("MLM/App/LibraryCommands.swift")
        for term in ["NSOpenPanel", "NSSavePanel", "Color.mlm", "MLMFont", "Color(red", "Color(hex"] {
            #expect(!src.contains(term), "found \(term)")
        }
        // No `mlm*` colour tokens (`.mlmInk`, `.mlmBase`, …) in rebuilt files.
        #expect(src.range(of: #"\.mlm[A-Z]"#, options: .regularExpression) == nil)
        #expect(src.contains(".fileImporter("))
        #expect(src.contains(".fileDialogMessage(LibraryFileType.panelMessage)"))
        #expect(LibraryFileType.panelMessage == "Choose a library file.")
        let all = try String(contentsOf: projectRoot.appendingPathComponent("MLM/Views/Sidebar/LibraryFooter.swift"), encoding: .utf8)
            + source("MLM/Views/Settings/SettingsView.swift")
        #expect(!all.contains("LibraryFilePanel"))
    }

    @Test func contentViewHostsTheLaunchStates() throws {
        let src = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains("LaunchRootView(launch: launch)"))
        #expect(src.contains(".modifier(LibraryFilePresentation(launch: launch))"))
        #expect(src.contains("private var isShellVisible: Bool { container.isInitialized && launch.setup == nil }"))
        for gone in ["FirstRunWizard", "Failed to Initialize", "Loading Library", "initializationError", "Color.black.opacity"] {
            #expect(!src.contains(gone), "ContentView still has \(gone)")
        }
        let root = try source("MLM/Views/Launch/LaunchRootView.swift")
        #expect(root.contains(".navigationTitle(\"MLM\")"))
    }

    @Test func appDelegateStartsTheCoordinatorAndGuardsQuit() throws {
        let src = try source("MLM/App/AppDelegate.swift")
        #expect(src.contains("LibraryLaunchCoordinator.shared.start()"))
        #expect(src.contains("QuitGuard.shared.shouldTerminate()"))
        #expect(src.contains("func applicationWillTerminate(_ notification: Notification)"))
        let backup = try source("MLM/Services/Backup/BackupService.swift")
        #expect(backup.contains("QuitGuard.shared.allowNextTermination()"))
    }

    @Test @MainActor func backupReasonLabel() {
        #expect(BackupSettingsViewModel.reasonLabel(.preAdoption) == "Before library file setup")
    }
}
