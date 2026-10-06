import Foundation
import Network

/// Local loopback HTTP server for OAuth 2.0 PKCE callbacks.
///
/// Listens on 127.0.0.1:19823, captures the first GET /callback request,
/// returns a success page, then shuts down.
///
/// Used instead of ASWebAuthenticationSession because the registered
/// redirect URI is http://127.0.0.1:19823/callback (not a custom scheme).
final class LoopbackOAuthServer: @unchecked Sendable {
    static let port: UInt16 = 19823
    static let redirectURI = "http://127.0.0.1:\(port)/callback"

    private let listenPort: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mlm.oauth.loopback", qos: .userInitiated)

    private let lock = NSLock()
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var hasResumed = false

    init(port: UInt16 = LoopbackOAuthServer.port) {
        self.listenPort = port
    }

    /// Start the server and wait for the OAuth callback.
    ///
    /// Suspends until the browser redirects to the loopback URI.
    /// Shuts down automatically after the first callback.
    ///
    /// Cancelling the calling task (the sign-in sheet's `Cancel`, its 5-minute timeout, `Open
    /// Browser Again`) stops the listener — the port is free for the next attempt — and throws
    /// `CancellationError` (S-SRC-OAUTH; it used to wait forever).
    ///
    /// One wait at a time, app-wide (one port): a second concurrent one throws
    /// `LoopbackOAuthError.alreadyWaiting` (W3-ADD review H5). The listener is created, assigned
    /// and cancelled on `queue` only.
    func waitForCallback() async throws -> (code: String, state: String) {
        guard Self.waiting.claim(id) else { throw LoopbackOAuthError.alreadyWaiting }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [self] cont in
                lock.lock()
                self.continuation = cont
                lock.unlock()
                if Task.isCancelled {
                    self.resumeOnce(throwing: CancellationError())
                    return
                }
                queue.async { self.startListener() }
            }
        } onCancel: { [self] in
            self.stop()
        }
    }

    /// The one waiting server (by id).
    private static let waiting = SignInGate()
    /// A loopback sign-in is waiting for its redirect.
    static var isWaiting: Bool { waiting.isHeld }
    private let id = UUID()
    /// Set on `queue` once the wait ended; a listener is never started after it.
    private var finished = false

    /// Stops listening and ends a pending wait with `CancellationError`.
    func stop() {
        resumeOnce(throwing: CancellationError())
        endListening()
    }

    /// Frees the port (on `queue`) and the app-wide slot.
    private func endListening() {
        Self.waiting.release(id)
        queue.async { [self] in
            finished = true
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Listener

    /// On `queue`.
    private func startListener() {
        guard !finished else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else {
            AppLogger.shared.error(
                "SC OAuth: server bind failed — invalid port \(listenPort)",
                source: "sc-oauth"
            )
            resumeOnce(throwing: LoopbackOAuthError.serverBindFailed(nil))
            return
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            AppLogger.shared.error(
                "SC OAuth: server bind failed on port \(listenPort): \(error)",
                source: "sc-oauth"
            )
            resumeOnce(throwing: LoopbackOAuthError.serverBindFailed(error))
            return
        }

        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                AppLogger.shared.error("SC OAuth: listener error: \(error)", source: "sc-oauth")
                self?.resumeOnce(throwing: error)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    // MARK: - Connection handler

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            if let error {
                AppLogger.shared.error("SC OAuth: connection error: \(error)", source: "sc-oauth")
                self?.resumeOnce(throwing: error)
                return
            }

            guard let data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8) else {
                self?.send(connection: connection, status: "400 Bad Request",
                           body: "<h2>Bad Request</h2><p>Empty request.</p>")
                self?.resumeOnce(throwing: LoopbackOAuthError.invalidCallback)
                return
            }

            // First line: "GET /callback?code=X&state=Y HTTP/1.1"
            let firstLine = request.split(separator: "\n").first.map(String.init) ?? ""
            let tokens = firstLine.split(separator: " ")

            guard tokens.count >= 2,
                  let rawPath = tokens.dropFirst().first.map(String.init),
                  let components = URLComponents(string: "http://127.0.0.1" + rawPath),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                AppLogger.shared.error(
                    "SC OAuth: invalid callback — missing 'code' in: \(firstLine.prefix(200))",
                    source: "sc-oauth"
                )
                self?.send(connection: connection, status: "400 Bad Request",
                           body: "<h2>Bad Request</h2><p>Missing authorization code.</p>")
                self?.resumeOnce(throwing: LoopbackOAuthError.invalidCallback)
                return
            }

            let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""

            self?.send(connection: connection, status: "200 OK", body: Self.successHTML)
            self?.listener?.cancel()
            self?.resumeOnce(returning: (code: code, state: state))
        }
    }

    // MARK: - HTTP helpers

    private func send(connection: NWConnection, status: String, body: String) {
        guard let bodyData = body.data(using: .utf8) else { return }
        let header = "HTTP/1.1 \(status)\r\n" +
                     "Content-Type: text/html; charset=utf-8\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private static let successHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>Authentication Successful</title>
    <style>
    body { font-family: -apple-system, sans-serif; text-align: center;
           padding: 80px 40px; color: #333; background: #f9f9f9; }
    h2 { color: #007aff; font-size: 24px; margin-bottom: 12px; }
    p { color: #666; font-size: 16px; }
    </style>
    </head>
    <body>
    <h2>Authentication Successful</h2>
    <p>You can close this tab and return to MLM.</p>
    </body>
    </html>
    """

    // MARK: - Single-shot continuation

    private func resumeOnce(returning value: (code: String, state: String)) {
        lock.lock()
        guard !hasResumed else { lock.unlock(); return }
        hasResumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        endListening()
        cont?.resume(returning: value)
    }

    private func resumeOnce(throwing error: Error) {
        lock.lock()
        guard !hasResumed else { lock.unlock(); return }
        hasResumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        endListening()
        cont?.resume(throwing: error)
    }
}

// MARK: - Errors

enum LoopbackOAuthError: LocalizedError {
    case serverBindFailed(Error?)
    case invalidCallback
    /// Another sign-in is waiting for its browser redirect (one port, one code verifier).
    case alreadyWaiting

    var errorDescription: String? {
        switch self {
        case .serverBindFailed(let underlying):
            "OAuth loopback server failed to start" +
                (underlying.map { ": \($0.localizedDescription)" } ?? " — is port 19823 already in use?")
        case .invalidCallback:
            "Invalid OAuth callback — missing authorization code"
        case .alreadyWaiting:
            "A sign-in is already waiting in your browser"
        }
    }
}
