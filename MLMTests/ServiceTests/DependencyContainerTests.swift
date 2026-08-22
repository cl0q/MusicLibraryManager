import Foundation
import Testing
@testable import MLM

@Suite("DependencyContainer token refresh wiring")
struct DependencyContainerTests {
    private actor RecordingTokenRefresh: TokenRefreshConfiguring {
        struct Snapshot: Sendable {
            let service: TokenStorage.Service?
            let tokenURL: URL?
            let clientId: String?
            let clientSecret: String?
            let startCalls: Int
        }

        private var service: TokenStorage.Service?
        private var tokenURL: URL?
        private var clientId: String?
        private var clientSecret: String?
        private var startCalls = 0

        func register(
            service: TokenStorage.Service,
            tokenURL: URL,
            clientId: String,
            clientSecret: String?
        ) {
            self.service = service
            self.tokenURL = tokenURL
            self.clientId = clientId
            self.clientSecret = clientSecret
        }

        func start() {
            startCalls += 1
        }

        func snapshot() -> Snapshot {
            Snapshot(
                service: service,
                tokenURL: tokenURL,
                clientId: clientId,
                clientSecret: clientSecret,
                startCalls: startCalls
            )
        }
    }

    @Test
    func soundCloudRefreshIsRegisteredAndStartedAtBoot() async {
        let refresh = RecordingTokenRefresh()

        await DependencyContainer.configureSoundCloudTokenRefresh(
            refresh,
            clientId: "client-id",
            clientSecret: "client-secret"
        )

        let snapshot = await refresh.snapshot()
        #expect(snapshot.service == .soundcloud)
        #expect(snapshot.tokenURL == SoundCloudClient.tokenURL)
        #expect(snapshot.clientId == "client-id")
        #expect(snapshot.clientSecret == "client-secret")
        #expect(snapshot.startCalls == 1)
    }
}
