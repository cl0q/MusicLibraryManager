import AuthenticationServices
import CryptoKit
import Foundation

/// OAuth 2.0 PKCE flow manager using ASWebAuthenticationSession.
///
/// Used by Spotify and SoundCloud clients for the authorization code flow
/// with Proof Key for Code Exchange (PKCE). Apple Music uses MusicKit
/// instead of OAuth.
///
/// ## Usage
/// ```swift
/// let manager = OAuthManager()
/// let code = try await manager.authorize(
///     authorizationURL: URL(string: "https://accounts.spotify.com/authorize")!,
///     clientId: "your_client_id",
///     redirectURI: "mlm://callback",
///     scopes: ["user-library-read", "playlist-read-private"],
///     callbackURLScheme: "mlm"
/// )
/// // Exchange `code` for tokens via the token endpoint
/// ```
final class OAuthManager: @unchecked Sendable {

    // MARK: - PKCE State

    /// PKCE verifier for the current authorization flow.
    private(set) var codeVerifier: String?

    // MARK: - Authorization

    /// Start an OAuth 2.0 PKCE authorization flow.
    ///
    /// Opens the system browser via `ASWebAuthenticationSession`, handles
    /// the redirect callback, and returns the authorization code.
    ///
    /// - Parameters:
    ///   - authorizationURL: The OAuth provider's authorization endpoint.
    ///   - clientId: The OAuth client ID.
    ///   - redirectURI: The redirect URI registered with the provider.
    ///   - scopes: OAuth scopes to request.
    ///   - callbackURLScheme: The custom URL scheme for the redirect (e.g., "mlm").
    ///   - extraParams: Additional query parameters for the authorization URL.
    /// - Returns: The authorization code from the redirect.
    @MainActor
    func authorize(
        authorizationURL: URL,
        clientId: String,
        redirectURI: String,
        scopes: [String],
        callbackURLScheme: String,
        extraParams: [String: String] = [:]
    ) async throws -> String {
        // Generate PKCE code verifier and challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        self.codeVerifier = verifier

        // Build the authorization URL
        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        for (key, value) in extraParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw OAuthError.invalidURL
        }

        // Launch ASWebAuthenticationSession
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.authenticationFailed(error))
                    }
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: OAuthError.noCodeInCallback)
                    return
                }

                // Check for error in callback
                if let errorParam = components.queryItems?.first(where: { $0.name == "error" })?.value {
                    continuation.resume(throwing: OAuthError.providerError(errorParam))
                    return
                }

                continuation.resume(returning: code)
            }

            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - Token Exchange

    /// Exchange an authorization code for tokens.
    ///
    /// - Parameters:
    ///   - tokenURL: The OAuth provider's token endpoint.
    ///   - code: The authorization code from the callback.
    ///   - clientId: The OAuth client ID.
    ///   - clientSecret: The OAuth client secret (if required).
    ///   - redirectURI: The redirect URI used in the authorization request.
    /// - Returns: Token response with access token, refresh token, and expiry.
    func exchangeCode(
        tokenURL: URL,
        code: String,
        clientId: String,
        clientSecret: String? = nil,
        redirectURI: String
    ) async throws -> TokenResponse {
        guard let verifier = codeVerifier else {
            throw OAuthError.noCodeVerifier
        }

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ]

        if let clientSecret {
            body["client_secret"] = clientSecret
        }

        return try await postTokenRequest(tokenURL: tokenURL, body: body, clientId: clientId, clientSecret: clientSecret)
    }

    /// Refresh an expired access token.
    ///
    /// - Parameters:
    ///   - tokenURL: The OAuth provider's token endpoint.
    ///   - refreshToken: The refresh token.
    ///   - clientId: The OAuth client ID.
    ///   - clientSecret: The OAuth client secret (if required).
    /// - Returns: Token response with new access token and expiry.
    func refreshAccessToken(
        tokenURL: URL,
        refreshToken: String,
        clientId: String,
        clientSecret: String? = nil
    ) async throws -> TokenResponse {
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]

        if let clientSecret {
            body["client_secret"] = clientSecret
        }

        return try await postTokenRequest(tokenURL: tokenURL, body: body, clientId: clientId, clientSecret: clientSecret)
    }

    // MARK: - Token Response

    /// Token response from the OAuth provider.
    struct TokenResponse: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let tokenType: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case scope
        }
    }

    // MARK: - Errors

    enum OAuthError: LocalizedError {
        case invalidURL
        case userCancelled
        case authenticationFailed(Error)
        case noCodeInCallback
        case noCodeVerifier
        case providerError(String)
        case tokenExchangeFailed(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid authorization URL"
            case .userCancelled: "Authorization was cancelled"
            case .authenticationFailed(let error): "Authentication failed: \(error.localizedDescription)"
            case .noCodeInCallback: "No authorization code in callback"
            case .noCodeVerifier: "No PKCE code verifier (authorize() must be called first)"
            case .providerError(let error): "Provider error: \(error)"
            case .tokenExchangeFailed(let code, let body): "Token exchange failed (HTTP \(code)): \(body)"
            }
        }
    }

    // MARK: - PKCE Helpers

    /// Generate a cryptographically random code verifier (43–128 characters).
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate a S256 code challenge from the verifier.
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - HTTP

    /// POST a token request and decode the response.
    private func postTokenRequest(
        tokenURL: URL,
        body: [String: String],
        clientId: String,
        clientSecret: String?
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Some providers need Basic auth header instead of body params
        if let clientSecret {
            let credentials = "\(clientId):\(clientSecret)"
            if let credData = credentials.data(using: .utf8) {
                let base64 = credData.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }

        let bodyString = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed(statusCode: 0, body: "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.tokenExchangeFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
