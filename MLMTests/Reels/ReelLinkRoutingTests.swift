import Foundation
import Testing
@testable import MLM

/// Reel links pasted or dropped anywhere go to Discover ▸ Reels (IMP-110): the same patterns
/// `ReelLinkFetcher` accepts, never Add from Link's "unsupported".
@Suite("ReelLinkRoutingTests", .serialized)
@MainActor
struct ReelLinkRoutingTests {
    private final class Presenter: QuickAddPresenting {
        var links: [LinkSuggestion] = []
        var reels: [URL] = []
        func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?) { links.append(link) }
        func presentReelLink(_ url: URL) { reels.append(url) }
    }

    @Test func reelInstagramTikTokAndShortsLinksGoToReels() {
        let router = QuickAddRouter()
        let presenter = Presenter()
        router.presenter = presenter
        let links = [
            "https://www.instagram.com/reel/Cx12345/",
            "https://www.tiktok.com/@user/video/7123456789",
            "https://vm.tiktok.com/ZMabc123/",
            "https://www.youtube.com/shorts/abcdEFG1234",
        ]
        for link in links { router.open(url: link) }
        #expect(presenter.reels.map(\.absoluteString) == links)
        #expect(presenter.links.isEmpty, "none of them is Add from Link's unsupported")
    }

    @Test func aSearchFieldLinkRowRoutesTheSameWay() {
        let router = QuickAddRouter()
        let presenter = Presenter()
        router.presenter = presenter
        router.open(.unsupported(host: "instagram.com", url: "https://www.instagram.com/reel/Cx12345/"))
        #expect(presenter.reels.count == 1 && presenter.links.isEmpty)
    }

    @Test func everythingElseIsUnchanged() {
        let router = QuickAddRouter()
        let presenter = Presenter()
        router.presenter = presenter
        router.open(url: "https://www.youtube.com/watch?v=abc")        // a plain video: a track
        router.open(url: "https://www.instagram.com/someprofile/")     // a profile: not a reel
        router.open(url: "https://bandcamp.com/x")
        #expect(presenter.reels.isEmpty)
        #expect(presenter.links.count == 3)
    }

    @Test func aPresenterThatIgnoresReelsAndAMissingWindowDoNothing() {
        final class Plain: QuickAddPresenting {
            var links: [LinkSuggestion] = []
            func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?) { links.append(link) }
        }
        let router = QuickAddRouter()
        let plain = Plain()
        router.presenter = plain
        router.open(url: "https://www.instagram.com/reel/Cx12345/")
        #expect(plain.links.isEmpty, "a reel link is not offered as a track")
        router.presenter = nil
        router.open(url: "https://www.instagram.com/reel/Cx12345/")
    }

    @Test func aLinkRoutedWhileReelsIsNotOpenWaitsForItAndShowsTheScope() {
        let router = ReelsDropRouter()
        _ = router.takePending()
        var shown = 0
        let token = NotificationCenter.default.addObserver(forName: .discoverShowReels, object: nil, queue: nil) { _ in shown += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let url = URL(string: "https://www.instagram.com/reel/Cx12345/")!
        router.route(url)
        #expect(router.pendingLinks == [url])
        #expect(shown == 1)
        #expect(router.takePending() == [url])
        #expect(router.pendingLinks.isEmpty)
    }
}
