import Foundation
import Testing
@testable import MLM

/// W3-SET: one account-state model (`Connected` / `Disconnected` / `Sign-in expired`) that
/// Settings ▸ Sources, the sidebar and the import sheet read (§11.1 #9), incl. the refresh
/// failure `TokenRefreshService` records.
@Suite("Source account states (W3-SET)")
@MainActor
struct SourceAccountsTests {

    private func makeDefaults() -> UserDefaults {
        let name = "SourceAccountsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func threeWordsOnly() {
        #expect(SourceAccountState.connected.word == "Connected")
        #expect(SourceAccountState.disconnected.word == "Disconnected")
        #expect(SourceAccountState.signInExpired(.keychainLocked).word == "Sign-in expired")
        #expect(SourceAccountState.signInExpired(.refreshRejected).word == "Sign-in expired")
    }

    @Test func keychainReadingsMapToStates() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        #expect(accounts.state(for: .soundcloud) == .disconnected, "never read: nothing to say")
        accounts.apply([.soundcloud: .valid, .spotify: .expiredWithoutRefresh, .appleMusic: .unreadable])
        #expect(accounts.state(for: .soundcloud) == .connected)
        #expect(accounts.state(for: .spotify) == .signInExpired(.expired))
        #expect(accounts.state(for: .appleMusic) == .signInExpired(.keychainLocked))
        #expect(accounts.unusableSignIns == [.spotify, .appleMusic])
    }

    @Test func anExpiredTokenWithARefreshTokenIsStillConnected() {
        let now = Date()
        #expect(SourceAccounts.classify(expiresAt: now.addingTimeInterval(-60), hasRefreshToken: true, now: now) == .valid)
        #expect(SourceAccounts.classify(expiresAt: now.addingTimeInterval(-60), hasRefreshToken: false, now: now) == .expiredWithoutRefresh)
        #expect(SourceAccounts.classify(expiresAt: nil, hasRefreshToken: false, now: now) == .valid)
    }

    @Test func aRejectedRefreshIsSignInExpiredUntilConnectOrDisconnect() {
        let defaults = makeDefaults()
        let accounts = SourceAccounts(defaults: defaults)
        accounts.apply([.spotify: .valid])
        accounts.recordRefreshRejected(.spotify)
        #expect(accounts.state(for: .spotify) == .signInExpired(.refreshRejected))
        // Remembered across launches.
        #expect(SourceAccounts(defaults: defaults).state(for: .spotify) == .signInExpired(.refreshRejected))
        accounts.didConnect(.spotify)
        #expect(accounts.state(for: .spotify) == .connected)
        #expect(SourceAccounts(defaults: defaults).refreshRejected.isEmpty)

        accounts.recordRefreshRejected(.soundcloud)
        accounts.didDisconnect(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .disconnected)
    }

    @Test func aSuccessfulRefreshClearsTheRejection() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.recordRefreshRejected(.soundcloud)
        accounts.recordRefreshSucceeded(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .connected)
    }

    @Test func accessStatusForwardsToTheOneModel() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        let status = TokenAccessStatus(accounts: accounts)
        accounts.apply([.soundcloud: .valid, .spotify: .valid])
        status.markInaccessible(.soundcloud)
        status.recordRefreshRejected(.spotify)
        #expect(accounts.state(for: .soundcloud) == .signInExpired(.keychainLocked))
        // The sidebar reads `inaccessibleServices`: it now covers the rejected refresh too.
        #expect(status.inaccessibleServices == [.soundcloud, .spotify])
        #expect(status.isInaccessible(.soundcloud))
        #expect(!status.isInaccessible(.spotify), "the keychain backoff stays keychain-only")
        status.markAccessible(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .connected)
    }

    @Test func sidebarLineFollowsTheModel() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.recordRefreshRejected(.spotify)
        #expect(SidebarModel.playlistSecondLine(sourceName: "spotify", unusableSignIns: accounts.unusableSignIns)
                == "Spotify sign-in expired")
        #expect(SidebarModel.playlistSecondLine(sourceName: "soundcloud", unusableSignIns: accounts.unusableSignIns) == nil)
    }

    @Test func onlyAProviderRefusalCountsAsRejected() {
        #expect(TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 400, body: "invalid_grant")))
        #expect(TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 401, body: "")))
        #expect(!TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 503, body: "")),
                "a server error is transient")
        #expect(!TokenRefreshService.isRejection(URLError(.notConnectedToInternet)), "offline is normal")
    }

    @Test func detailSentences() {
        #expect(SourceAccounts.detail(for: .signInExpired(.expired), service: .spotify)
                == "imports and refreshes from Spotify are paused")
        #expect(SourceAccounts.detail(for: .connected, service: .soundcloud, lastRefreshed: "today, 09:14")
                == "last refreshed today, 09:14")
    }

    @Test func spotifyIsRegisteredForRefreshOnlyWithAClientID() async {
        let recorder = RefreshRecorder()
        await DependencyContainer.configureSpotifyTokenRefresh(recorder, clientId: "", clientSecret: nil)
        #expect(await recorder.services.isEmpty)
        await DependencyContainer.configureSpotifyTokenRefresh(recorder, clientId: "id", clientSecret: "secret")
        #expect(await recorder.services == [.spotify])
        #expect(await recorder.urls == [SpotifyClient.tokenURL])
    }
}

private actor RefreshRecorder: TokenRefreshConfiguring {
    var services: [TokenStorage.Service] = []
    var urls: [URL] = []
    func register(service: TokenStorage.Service, tokenURL: URL, clientId: String, clientSecret: String?) async {
        services.append(service)
        urls.append(tokenURL)
    }
    func start() async {}
}
