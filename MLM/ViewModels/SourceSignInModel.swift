import Foundation
import Observation

// MARK: - Browser sign-in hand-off (S-SRC-OAUTH, DEC-004)

/// The browser sign-in, said where it was asked for (import sheet, Add from Link): MLM opens
/// the source's sign-in page in the default browser and says it is waiting, with `Cancel`
/// and `Open Browser Again`; it gives up after 5 minutes (`Sign-in wasn’t finished · Try
/// Again`). On success the place that asked continues by itself (`onSuccess`) and the status
/// bar says `‹Source› connected`. It used to wait forever without a word.
///
/// One sign-in waits at a time (the loopback redirect has one port and `OAuthManager` one code
/// verifier): a second is refused with `A sign-in is already waiting in your browser`. An
/// attempt ends — and frees the port — on Cancel, on timeout, when its view goes away and when
/// the model is released (review H5).
///
/// The one sign-in entry point is `SourceAccountStateReading.signIn` (→ the source client's
/// OAuth flow); W3-SET's Settings rows can use the same model.
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
    @ObservationIgnored private let tasks = SignInTasks()
    @ObservationIgnored private var generation = 0

    /// App-wide: which model's attempt is waiting in the browser.
    static let sharedGate = SignInGate()
    @ObservationIgnored private let gate: SignInGate

    init(service: TokenStorage.Service, accounts: any SourceAccountStateReading,
         timeout: Duration = .seconds(300),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         post: @escaping (String) -> Void = { _ in },
         gate: SignInGate = SourceSignInModel.sharedGate) {
        self.gate = gate
        self.service = service
        self.accounts = accounts
        self.timeout = timeout
        self.sleep = sleep
        self.post = post
    }

    deinit {
        // A released model never leaves the browser wait (and its port) behind.
        tasks.cancelAll()
        gate.release(tasks.owner)
    }

    var sourceName: String { service.displayName }
    var title: String { "Sign in to \(sourceName)" }
    var waitingText: String { "Waiting for \(sourceName) in your browser…" }
    static let waitingDetail = "Finish signing in there. MLM continues by itself and keeps your place."
    static let timedOutText = "Sign-in wasn’t finished"
    static let alreadyWaitingText = "A sign-in is already waiting in your browser"

    var isWaiting: Bool { phase == .waiting }

    /// Opens the browser and waits. A second call on this model (`Open Browser Again`, `Try
    /// Again`) ends its running attempt first; another model's waiting attempt refuses it.
    func start(onSuccess: @escaping @MainActor () -> Void = {}) {
        tasks.cancelAll()
        guard gate.claim(tasks.owner) else {
            phase = .failed(Self.alreadyWaitingText)
            return
        }
        generation += 1
        let current = generation
        phase = .waiting
        let accounts = self.accounts
        let service = self.service
        let attempt = Task { [weak self] in
            do {
                try await accounts.signIn(service)
                guard let self, self.generation == current else { return }
                self.finish(.succeeded)
                self.post("\(service.displayName) connected")
                onSuccess()
            } catch {
                guard let self, self.generation == current, self.phase == .waiting else { return }
                if error is CancellationError || Task.isCancelled {
                    self.finish(.idle)
                } else if case .alreadyWaiting? = error as? LoopbackOAuthError {
                    self.finish(.failed(Self.alreadyWaitingText))
                } else {
                    self.finish(.failed("Couldn’t sign in to \(service.displayName) — \(error.localizedDescription)"))
                }
            }
        }
        let sleep = self.sleep
        let timeout = self.timeout
        let timer = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            guard let self, self.generation == current, self.phase == .waiting else { return }
            self.finish(.timedOut)
        }
        tasks.set(attempt: attempt, timer: timer)
    }

    /// `Cancel` (or the view going away): stops waiting; the place that asked shows its
    /// `Reconnect` / `Connect` again.
    func cancel() {
        generation += 1
        finish(.idle)
    }

    private func finish(_ phase: Phase) {
        tasks.cancelAll()
        gate.release(tasks.owner)
        self.phase = phase
    }
}

/// The running attempt and its timer; cancellable from `deinit` (any thread).
final class SignInTasks: @unchecked Sendable {
    let owner = UUID()
    private let lock = NSLock()
    private var attempt: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func set(attempt: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock(); self.attempt = attempt; self.timer = timer; lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let attempt = self.attempt, timer = self.timer
        self.attempt = nil
        self.timer = nil
        lock.unlock()
        attempt?.cancel()
        timer?.cancel()
    }
}

/// One browser sign-in at a time, app-wide.
final class SignInGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: UUID?

    /// `true` when free or already held by `owner`.
    func claim(_ owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let holder, holder != owner { return false }
        holder = owner
        return true
    }

    func release(_ owner: UUID) {
        lock.lock(); if holder == owner { holder = nil }; lock.unlock()
    }

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return holder != nil }
}
