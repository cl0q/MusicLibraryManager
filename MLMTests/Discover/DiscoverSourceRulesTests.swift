import Foundation
import Testing
@testable import MLM

/// Source rules of the Discover and Similar views (UC §22 "Never", V-SIMILAR.N07, DEC-043).
@Suite("DiscoverSourceRulesTests")
struct DiscoverSourceRulesTests {
    private static func swiftFiles(under directories: [String]) throws -> [(path: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [(String, String)] = []
        for directory in directories {
            let url = root.appendingPathComponent(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            for name in names {
                found.append(("\(directory)/\(name)", try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)))
            }
        }
        return found
    }

    private static let files = ["MLM/Views/Discover", "MLM/Views/Similar"]

    @Test func theViewsUseNoCustomPaletteToastsOrAvailabilityChecks() throws {
        let sources = try Self.swiftFiles(under: Self.files)
        #expect(sources.count >= 5)
        for (path, code) in sources {
            #expect(!code.contains("mlm"), "\(path): no mlm* tokens or fonts (UC §22)")
            #expect(!code.contains("Toast"), "\(path): confirmations go to the status bar")
            #expect(!code.contains("#available"), "\(path): macOS 27 only")
            #expect(!code.contains("MLMGlass"), "\(path): no private glass wrapper")
        }
    }

    @Test func noCapsuleWordsAndNoOldVerbs() throws {
        for (path, code) in try Self.swiftFiles(under: Self.files) {
            #expect(!code.contains("SOUNDCLOUD") && !code.contains("LASTFM"), "\(path): the source is a word with a dot, not a capsule")
            #expect(!code.contains("Add to library"), "\(path): it is Keep now")
            #expect(!code.contains("\"Delete"), "\(path): nothing here deletes (V-SIMILAR.N07)")
            #expect(!code.contains("Delete…"), "\(path): Dismiss has no alert")
            #expect(!code.contains(".alert("), "\(path): Dismiss and Keep have no alert (UC-PRIM-10)")
        }
    }

    @Test func similarNeverReachesADeletePath() throws {
        for (path, code) in try Self.swiftFiles(under: ["MLM/Views/Similar"]) + (try Self.swiftFiles(under: ["MLM/ViewModels"]).filter { $0.path.hasSuffix("SimilarModel.swift") }) {
            #expect(!code.contains("removeFromLibrary"), "\(path)")
            #expect(!code.contains("trashItem") && !code.contains("DiscoveryReviewService"), "\(path)")
            #expect(!code.contains(".delete("), "\(path)")
        }
    }
}
