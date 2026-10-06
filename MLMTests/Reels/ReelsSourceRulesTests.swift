import Foundation
import Testing
@testable import MLM

/// Source rules of the Reels surfaces (UC §22 "Never", V-REELS.E13, E20, THOUGHTS §10).
@Suite("ReelsSourceRulesTests")
struct ReelsSourceRulesTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(under directory: String) throws -> [(path: String, code: String)] {
        let url = root.appendingPathComponent(directory)
        var found: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let name = enumerator?.nextObject() as? String {
            guard name.hasSuffix(".swift") else { continue }
            found.append(("\(directory)/\(name)", try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)))
        }
        return found
    }

    private static func views() throws -> [(path: String, code: String)] {
        try swiftFiles(under: "MLM/Views/Reels")
    }

    private static func reelsSources() throws -> [(path: String, code: String)] {
        try views() + swiftFiles(under: "MLM/Services/Reels")
            + swiftFiles(under: "MLM/ViewModels").filter { $0.path.hasSuffix("ReelsModel.swift") }
    }

    @Test func theViewsUseNoCustomPaletteToastsOrAvailabilityChecks() throws {
        let sources = try Self.views()
        #expect(sources.count == 5)
        for (path, code) in sources {
            #expect(!code.contains("mlm"), "\(path): no mlm* tokens or fonts (UC §22)")
            #expect(!code.contains("Toast"), "\(path): confirmations go to the status bar")
            #expect(!code.contains("#available"), "\(path): macOS 27 only")
            #expect(!code.contains("MLMGlass"), "\(path): no private glass wrapper")
            #expect(!code.contains(".hiddenTitleBar"), "\(path): the native toolbar stays")
        }
    }

    @Test func noGermanLabelsNoJargonAndNoAlbumReels() throws {
        for (path, code) in try Self.reelsSources() {
            #expect(!code.contains("album: \"Reels\""), "\(path): a downloaded result has no album (DEC-013)")
        }
        for (path, code) in try Self.views() + Self.swiftFiles(under: "MLM/ViewModels").filter({ $0.path.hasSuffix("ReelsModel.swift") }) {
            #expect(!code.contains("Per Audio erkennen"), "\(path): English only (V-REELS.E13)")
            #expect(!code.contains("Music Identification"), "\(path): jargon label")
            #expect(!code.contains("Unified Search Results"), "\(path): jargon label")
            #expect(!code.contains("OCR"), "\(path): no OCR label")
            #expect(!code.contains("Deletion Error"), "\(path): the delete failure is a status-bar sentence (A-REELS-DELETEERROR)")
            #expect(!code.contains("Search & download") && !code.contains("Search &amp; download"), "\(path): the button is Search")
        }
    }

    @Test func spaceIsNeverAMenuKeyEquivalent() throws {
        for (path, code) in try Self.views() {
            #expect(!code.contains("keyboardShortcut(.space"), "\(path): Space is never a key equivalent (UC-KEY-01)")
            #expect(!code.contains("keyboardShortcut(.return"), "\(path): plain Return is never a key equivalent")
        }
    }

    @Test func theViewsAreTheOnlyWayToDeleteAndTheyAskFirst() throws {
        let view = try #require(try Self.views().first { $0.path.hasSuffix("ReelsView.swift") })
        #expect(view.code.contains(".alert("), "A-REELS-DELETE is attached to the view")
        #expect(view.code.contains("role: .destructive"))
        #expect(view.code.contains("role: .cancel"), "Cancel is the safe default")
        #expect(view.code.contains(".onDeleteCommand"), "⌫ on the list opens the alert (UC-KEY-17)")
        #expect(view.code.contains(".dropTarget(.reels"), "the whole view is a drop target (V-REELS.N02)")
        #expect(view.code.contains(".fileDialogMessage(\"Choose video files or a folder of videos.\")"), "UC-SHEET-25")
    }

    @Test func theOldInboxIsGone() throws {
        #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("MLM/Views/ReelsInbox").path))
        #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("MLM/Services/Common/ReelDeletionController.swift").path))
    }

    @Test func noResultPreviewButtonWithoutAStreamPreview() throws {
        let sections = try #require(try Self.views().first { $0.path.hasSuffix("ReelWorkbenchSections.swift") })
        #expect(!sections.code.contains("Button(\"Preview\")"), "no dead control until a stream preview exists")
    }
}
