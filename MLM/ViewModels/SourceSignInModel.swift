import Foundation
import Observation

// MARK: - Browser sign-in hand-off (S-SRC-OAUTH, DEC-004)

/// The browser sign-in, said where it was asked for (import sheet, Add from Link): MLM opens
/// the source's sign-in page in the default browser and says it is waiting, with `Cancel`
/// and `Open Browser Again`; it gives up after 5 minutes (`Sign-in wasn’t finished · Try
/// Again`). On success the place that asked continues by itself (`onSuccess`) and the status
/// bar says `‹Source› connected`. It used to wait forever without a word.
///
/// The one sign-in entry point is `SourceAccountStateReading.signIn` (→ the source client's
/// OAuth flow); W3-SET's Settings rows use the same model.
@MainActor
@Observable
final class SourceSignInModel {
    enum Phase: Equatable {
        case idle
        case waiting
        /// No answer within the timeout.
        case timedOut
        case failed(String)
        case succeeded
    }

    let service: TokenStorage.Service
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let accounts: any SourceAccountStateReading
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let post: (String) -> Void
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(service: TokenStorage.Service, accounts: any SourceAccountStateReading,
         timeout: Duration = .seconds(300),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         post: @escaping (String) -> Void = { _ in }) {
        self.service = service
        self.accounts = accounts
        self.timeout = timeout
        self.sleep = sleep
        self.post = post
    }

    var sourceName: String { service.displayName }
    var title: String { "Sign in to \(sourceName)" }
    var waitingText: String { "Waiting for \(sourceName) in your browser…" }
    static let waitingDetail = "Finish signing in there. MLM continues by itself and keeps your place."
    static let timedOutText = "Sign-in wasn’t finished"

    var isWaiting: Bool { phase == .waiting }

    /// Opens the browser and waits. A second call (`Open Browser Again`, `Try Again`) ends
    /// the running attempt first, so its loopback listener is free again.
    func start(onSuccess: @escaping @MainActor () -> Void = {}) {
        attempt?.cancel()
        timer?.cancel()
        generation += 1
        let current = generation
        phase = .waiting
        let accounts = self.accounts
        let service = self.service
        attempt = Task { [weak self] in
            do {
                try await accounts.signIn(service)
                guard let self, self.generation == current else { return }
                self.timer?.cancel()
                self.phase = .succeeded
                self.post("\(service.displayName) connected")
                onSuccess()
            } catch {
                guard let self, self.generation == current, self.phase == .waiting else { return }
                self.timer?.cancel()
                if error is CancellationError || Task.isCancelled {
                    self.phase = .idle
                } else {
                    self.phase = .failed("Couldn’t sign in to \(service.displayName) — \(error.localizedDescription)")
                }
            }
        }
        let sleep = self.sleep
        let timeout = self.timeout
        timer = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            guard let self, self.generation == current, self.phase == .waiting else { return }
            self.attempt?.cancel()
            self.phase = .timedOut
        }
    }

    /// `Cancel`: stops waiting; the place that asked shows its `Reconnect` / `Connect` again.
    func cancel() {
        generation += 1
        attempt?.cancel()
        timer?.cancel()
        phase = .idle
    }
}
