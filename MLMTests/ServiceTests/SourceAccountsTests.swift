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
        #expect(SourceAccountState.connected(account: nil).word == "Connected")
        #expect(SourceAccountState.disconnected.word == "Disconnected")
        #expect(SourceAccountState.keychainLocked.word == "Sign-in expired")
        #expect(SourceAccountState.signInExpired.word == "Sign-in expired")
    }

    @Test func keychainReadingsMapToStates() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        #expect(accounts.state(for: .soundcloud) == .disconnected, "never read: nothing to say")
        accounts.apply([.soundcloud: .valid, .spotify: .expiredWithoutRefresh, .appleMusic: .unreadable])
        #expect(accounts.state(for: .soundcloud) == .connected(account: nil))
        #expect(accounts.state(for: .spotify) == .signInExpired)
        #expect(accounts.state(for: .appleMusic) == .keychainLocked)
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
        #expect(accounts.state(for: .spotify) == .signInExpired)
        // Remembered across launches.
        #expect(SourceAccounts(defaults: defaults).state(for: .spotify) == .signInExpired)
        accounts.didConnect(.spotify)
        #expect(accounts.state(for: .spotify) == .connected(account: nil))
        #expect(SourceAccounts(defaults: defaults).refreshRejected.isEmpty)

        accounts.recordRefreshRejected(.soundcloud)
        accounts.didDisconnect(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .disconnected)
    }

    @Test func aSuccessfulRefreshClearsTheRejection() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.recordRefreshRejected(.soundcloud)
        accounts.recordRefreshSucceeded(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .connected(account: nil))
    }

    @Test func accessStatusForwardsToTheOneModel() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        let status = TokenAccessStatus(accounts: accounts)
        accounts.apply([.soundcloud: .valid, .spotify: .valid])
        status.markInaccessible(.soundcloud)
        status.recordRefreshRejected(.spotify)
        #expect(accounts.state(for: .soundcloud) == .keychainLocked)
        // The sidebar reads `inaccessibleServices`: it now covers the rejected refresh too.
        #expect(status.inaccessibleServices == [.soundcloud, .spotify])
        #expect(status.isInaccessible(.soundcloud))
        #expect(!status.isInaccessible(.spotify), "the keychain backoff stays keychain-only")
        status.markAccessible(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .connected(account: nil))
    }

    @Test func sidebarLineFollowsTheModel() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.recordRefreshRejected(.spotify)
        #expect(SidebarModel.playlistSecondLine(sourceName: "spotify", unusableSignIns: accounts.unusableSignIns)
                == "Spotify sign-in expired")
        #expect(SidebarModel.playlistSecondLine(sourceName: "soundcloud", unusableSignIns: accounts.unusableSignIns) == nil)
    }

    // MARK: Review S1

    @Test func reconnectGoesToTheBrowserForARefusedSignIn() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.apply([.spotify: .valid])
        accounts.recordRefreshRejected(.spotify)
        // The rejected token is still readable — Reconnect must not stop at a keychain read.
        #expect(ReconnectStep.step(for: accounts.state(for: .spotify)) == .browserSignIn)
        accounts.didConnect(.spotify)   // what a successful `signIn` does
        #expect(accounts.state(for: .spotify) == .connected(account: nil))
        #expect(accounts.refreshRejected.isEmpty)
    }

    @Test func reconnectReadsALockedKeychainOnce() {
        let accounts = SourceAccounts(defaults: makeDefaults())
        accounts.apply([.soundcloud: .unreadable])
        #expect(ReconnectStep.step(for: accounts.state(for: .soundcloud)) == .allowKeychainAccess)
        accounts.markKeychainReadable(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .connected(account: nil))
    }

    @Test func aDeniedPromptIsNeitherPersistedNorARefusal() {
        let defaults = makeDefaults()
        let accounts = SourceAccounts(defaults: defaults)
        accounts.apply([.soundcloud: .unreadable])
        accounts.recordKeychainDenied(.soundcloud)
        #expect(accounts.state(for: .soundcloud) == .signInExpired)
        #expect(accounts.expiredCause(for: .soundcloud) == .keychainDenied)
        #expect(!SourceAccounts.detail(for: .signInExpired, cause: .keychainDenied, service: .soundcloud).contains("refused"))
        #expect(ReconnectStep.step(for: accounts.state(for: .soundcloud)) == .browserSignIn)
        #expect(SourceAccounts(defaults: defaults).state(for: .soundcloud) == .disconnected, "not remembered")
    }

    @Test func onlyAProviderRefusalCountsAsRejected() {
        #expect(TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 400, body: "invalid_grant")))
        #expect(TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 401, body: "")))
        #expect(!TokenRefreshService.isRejection(OAuthManager.OAuthError.tokenExchangeFailed(statusCode: 503, body: "")),
                "a server error is transient")
        #expect(!TokenRefreshService.isRejection(URLError(.notConnectedToInternet)), "offline is normal")
    }

    @Test func detailSentences() {
        #expect(SourceAccounts.detail(for: .signInExpired, cause: .expired, service: .spotify)
                == "imports and refreshes from Spotify are paused")
        #expect(SourceAccounts.detail(for: .signInExpired, cause: .refreshRejected, service: .spotify)
                .hasPrefix("Spotify refused the saved sign-in"))
        #expect(SourceAccounts.detail(for: .connected(account: nil), cause: nil, service: .soundcloud,
                                      lastRefreshed: "today, 09:14") == "last refreshed today, 09:14")
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
