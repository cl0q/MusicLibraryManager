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
        // The library-file icon (ICON-MLIBM variant A, DEC-033); W3-LAUNCH replaces Step-0
        // decision 11's "no custom icon yet".
        #expect(plist.contains("<key>CFBundleTypeIconFile</key><string>LibraryFile</string>"))
        #expect(plist.contains("<key>UTTypeIconFile</key><string>LibraryFile</string>"))
        #expect(!plist.contains("TODO"))
    }

    @Test func libraryFileIconIsBuiltAndInstalled() throws {
        let icon = projectRoot.appendingPathComponent("MLM/Resources/LibraryFile.icns")
        let data = try Data(contentsOf: icon)
        #expect(data.prefix(4) == Data("icns".utf8))
        let script = try source("scripts/run.sh")
        #expect(script.contains(#"cp "${LIBRARY_ICON_SRC}" "${APP_BUNDLE}/Contents/Resources/LibraryFile.icns""#))
        #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("scripts/render-library-icon.swift").path))
        let package = try source("Package.swift")
        #expect(package.contains(#".process("Resources/LibraryFile.icns")"#))
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
        // Through the presenter, which brings the main window forward first (UC-WIN-01).
        #expect(src.contains("MainWindowPresenter.shared.openLibrary(url, launch: LibraryLaunchCoordinator.shared)"))
        let presenter = try source("MLM/App/Commands/MainWindowPresenter.swift")
        #expect(presenter.contains("await launch.handleOpen(url)"))
    }

    /// One MLM window only: a `WindowGroup` opens a second window for every library file
    /// opened in Finder, and a second switch alert then cancels the relaunch.
    @Test func appHasExactlyOneMainWindow() throws {
        let app = try source("MLM/App/MLMApp.swift")
        #expect(!app.contains("WindowGroup"))
        #expect(app.contains("Window(\"MLM\", id: \"main\")"))
    }

    /// Termination is requested after the alert has gone, and a waiter left behind by a
    /// cancelled termination is stopped instead of relaunching MLM later.
    @Test func relaunchNeverLeavesAWaiterBehind() throws {
        let src = try source("MLM/Services/Backup/BackupService.swift")
        let start = try #require(src.range(of: "static func relaunchApp()"))
        let body = String(src[start.lowerBound...].prefix(2500))
        #expect(body.contains("DispatchQueue.main.async"))
        #expect(body.contains("if process.isRunning"))
        #expect(body.contains("process.terminate()"))
    }

    @Test func fileMenuHasTheLibraryItems() throws {
        let src = try source("MLM/App/LibraryCommands.swift")
        for string in [" — Not found", " — Not connected"] {
            #expect(src.contains(string), "missing menu copy: \(string)")
        }
        for item in ["CommandButton(.newLibrary", "CommandButton(.openLibrary", "CommandSubmenu(.openRecent",
                     "CommandButton(.showLibraryFileInFinder"] {
            #expect(src.contains(item), "missing File menu item: \(item)")
        }
        let catalog = try source("MLM/App/Commands/MenuCatalog.swift")
        for string in ["\"New Library…\"", "\"Open Library…\", shortcut: .cmd(\"o\")", "\"Open Recent\"",
                       "\"Show Library File in Finder\""] {
            #expect(catalog.contains(string), "missing catalog entry: \(string)")
        }
        // Clear Menu exists (UC-MENU-05) but stays pending: Open Recent lists every library MLM
        // knows; there is no separate recent list to clear (W3-LAUNCH).
        #expect(src.contains("CommandButton(.clearRecentLibraries)"))
        #expect(catalog.contains("title: \"Clear Menu\""))
        let file = try source("MLM/App/Commands/FileCommands.swift")
        #expect(file.contains("LibraryCommands(launch: launch)"))
    }

    @Test func switchAlertUsesApprovedCopy() throws {
        let src = try source("MLM/Views/Launch/LibraryFilePresentation.swift")
        for string in [
            "Switch to “", "MLM quits and reopens with “", "Switch and Relaunch", "Cancel",
            "RunningWorkSummary(operations: ActivityCenter.shared.activeOperations)",
        ] {
            #expect(src.contains(string), "missing switch copy: \(string)")
        }
    }

    @Test func libraryTabShowsTheLibraryFileSection() throws {
        let src = try source("MLM/Views/Settings/LibrarySetupView.swift")
        for string in ["Library file", "Show in Finder"] {
            #expect(src.contains(string), "missing Library tab copy: \(string)")
        }
        // The launch choice is about MLM, not one library: Settings ▸ General (W1-2, UC-WIN-04).
        #expect(!src.contains("\"Open the last library at launch\""))
        let general = try source("MLM/Views/Settings/GeneralSettingsView.swift")
        for string in [
            "Open the last library at launch", "When off, MLM asks which library to open at launch.",
        ] {
            #expect(general.contains(string), "missing General tab copy: \(string)")
        }
    }

    @Test func duplicatePromptUsesApprovedCopy() throws {
        let src = try source("MLM/Views/Launch/LibraryFilePresentation.swift")
        for string in [
            "is a copy of", "To open it, MLM makes the copy a separate library.", "is not changed.",
            "Open as Separate Library", "Cancel",
        ] {
            #expect(src.contains(string), "missing duplicate copy: \(string)")
        }
    }
}
