import Testing
import Foundation

/// A3 Wave 4 source-scan contracts: the `.mlibm` document type in the generated Info.plist
/// (A0 D9), open-file handling, the File menu items and the Library tab section, all with
/// the approved copy (UI-GROUNDTRUTH §2.6 / §3.14 / §5.6).
@Suite("Library Finder integration contract (A3 Wave 4)")
struct LibraryFinderIntegrationTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The Info.plist heredoc in scripts/run.sh.
    private var plist: String {
        get throws {
            let script = try source("scripts/run.sh")
            let start = try #require(script.range(of: "<<'PLIST'"))
            let end = try #require(script.range(of: "\nPLIST\n", range: start.upperBound..<script.endIndex))
            return String(script[start.upperBound..<end.lowerBound])
        }
    }

    @Test func plistExportsTheLibraryFileType() throws {
        let plist = try plist
        #expect(plist.contains("<key>UTExportedTypeDeclarations</key>"))
        #expect(plist.contains("<string>com.ilczuk.mlm.library</string>"))
        #expect(plist.contains("<string>com.apple.package</string>"))
        #expect(plist.contains("<string>public.data</string>"))
        #expect(plist.contains("<key>public.filename-extension</key>"))
        #expect(plist.contains("<string>mlibm</string>"))
        #expect(plist.contains("<string>MLM Library File</string>"))
    }

    @Test func plistDeclaresMLMAsOwnerOfLibraryFiles() throws {
        let plist = try plist
        #expect(plist.contains("<key>CFBundleDocumentTypes</key>"))
        #expect(plist.contains("<key>CFBundleTypeRole</key><string>Editor</string>"))
        #expect(plist.contains("<key>LSHandlerRank</key><string>Owner</string>"))
        #expect(plist.contains("<key>LSTypeIsPackage</key><true/>"))
        #expect(plist.contains("<key>LSItemContentTypes</key>"))
        // No custom icon yet (Step-0 decision 11): macOS derives one from the app icon.
        #expect(!plist.contains("CFBundleTypeIconFile"))
    }

    @Test func plistIsStillWellFormed() throws {
        let data = Data(try plist.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let declarations = try #require(parsed?["UTExportedTypeDeclarations"] as? [[String: Any]])
        #expect(declarations.first?["UTTypeIdentifier"] as? String == "com.ilczuk.mlm.library")
        let documents = try #require(parsed?["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect((documents.first?["LSItemContentTypes"] as? [String]) == ["com.ilczuk.mlm.library"])
        #expect(parsed?["CFBundleIdentifier"] as? String == "com.ilczuk.mlm")
    }

    @Test func appDelegateRoutesOpenedFilesThroughTheCoordinator() throws {
        let src = try source("MLM/App/AppDelegate.swift")
        #expect(src.contains("func application(_ application: NSApplication, open urls: [URL])"))
        #expect(src.contains("LibraryLaunchCoordinator.shared.handleOpen("))
    }

    @Test func fileMenuHasTheLibraryItems() throws {
        let src = try source("MLM/App/LibraryCommands.swift")
        for string in ["New Library…", "Open Library…", "Open Recent", " — Not found", " — Not connected"] {
            #expect(src.contains(string), "missing menu copy: \(string)")
        }
        #expect(src.contains(".keyboardShortcut(\"o\")"))
        #expect(!src.contains("Clear Menu"))
        let app = try source("MLM/App/MLMApp.swift")
        #expect(app.contains("LibraryCommands("))
    }

    @Test func switchAlertUsesApprovedCopy() throws {
        let src = try source("MLM/Views/ContentView/ContentView.swift")
        for string in [
            "Switch to \\\"", "MLM relaunches to open this library. Finish active downloads and syncs first.",
            "Relaunch", "Cancel",
        ] {
            #expect(src.contains(string), "missing switch copy: \(string)")
        }
    }

    @Test func libraryTabShowsTheLibraryFileSection() throws {
        let src = try source("MLM/Views/Settings/LibrarySetupView.swift")
        for string in [
            "Library file", "Show in Finder", "Open the last library at launch",
            "When off, MLM asks which library to open at launch.",
        ] {
            #expect(src.contains(string), "missing Library tab copy: \(string)")
        }
    }

    @Test func duplicatePromptUsesApprovedCopy() throws {
        let src = try source("MLM/Views/Shared/LibraryLaunchStateView.swift")
        for string in [
            "is a copy of", "To open it, MLM makes the copy a separate library.", "is not changed.",
            "Open as separate library", "Cancel",
        ] {
            #expect(src.contains(string), "missing duplicate copy: \(string)")
        }
    }
}
