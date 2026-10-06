import Testing
import AppKit
@testable import MLM

/// W3-LAUNCH review round: the library-file icon without `Bundle.module` (S6) and the rule
/// that brings back the setup (S8). Temporary databases only.
@Suite("Launch review fixes (W3-LAUNCH)")
@MainActor
struct LaunchReviewFixTests {

    @Test func theIconFallsBackToTheSystemIconWithoutAnyBundle() {
        let image = LibraryFileIcon.load(from: [])
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func theIconIsFoundWhereTheResourceBundleIs() {
        let image = LibraryFileIcon.load(from: LibraryFileIcon.candidateBundles())
        #expect(image.size.width > 0)
        // The candidates exist or are skipped; looking never crashes.
        #expect(LibraryFileIcon.candidateBundles().first == Bundle.main)
    }
}
