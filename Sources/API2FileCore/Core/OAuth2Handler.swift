import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - OAuth2Error

/// Errors that can occur during the OAuth2 flow.
public enum OAuth2Error: Error, LocalizedError, Sendable {
    case missingConfiguration(String)
    case invalidAuthorizationURL
    case callbackServerFailed(String)
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case noTokenAvailable
    case stateMismatch

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let field):
            return "OAuth2 configuration missing required field: \(field)"
        case .invalidAuthorizationURL:
            return "Failed to construct a valid authorization URL."
        case .callbackServerFailed(let reason):
            return "OAuth2 callback server failed: \(reason)"
        case .authorizationFailed(let reason):
            return "OAuth2 authorization failed: \(reason)"
        case .tokenExchangeFailed(let reason):
            return "OAuth2 token exchange failed: \(reason)"
        case .refreshFailed(let reason):
            return "OAuth2 token refresh failed: \(reason)"
        case .noTokenAvailable:
            return "No OAuth2 token available. Please authenticate first."
        case .stateMismatch:
            return "OAuth2 state parameter mismatch — possible CSRF attack."
        }
    }
}

// MARK: - OAuth2Handler

/// Handles the OAuth2 Authorization Code flow:
/// opens the browser, runs a temporary callback server, exchanges the code for tokens,
/// and persists/refreshes tokens via KeychainManager.
public actor OAuth2Handler {

    private let config: AuthConfig
    private let keychain: KeychainManager

    // MARK: - Init

    public init(config: AuthConfig, keychain: KeychainManager = KeychainManager()) {
        self.config = config
        self.keychain = keychain
    }

    // MARK: - Public API

    /// Start the full OAuth2 Authorization Code flow:
    /// 1. Open browser with authorization URL
    /// 2. Wait for the redirect callback on a local HTTP server
    /// 3. Exchange the authorization code for tokens
    /// 4. Save tokens to Keychain
    public func authenticate() async throws -> OAuth2Token {
        guard let authorizeUrl = config.authorizeUrl else {
            throw OAuth2Error.missingConfiguration("authorizeUrl")
        }
        guard let tokenUrl = config.tokenUrl else {
            throw OAuth2Error.missingConfiguration("tokenUrl")
        }
        let port = config.callbackPort ?? 8080

        // Generate a random state parameter for CSRF protection
        let state = UUID().uuidString

        // Build authorization URL
        guard var components = URLComponents(string: authorizeUrl) else {
            throw OAuth2Error.invalidAuthorizationURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "response_type", value: "code"))
        queryItems.append(URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)/callback"))
        queryItems.append(URLQueryItem(name: "state", value: state))
        if let scopes = config.scopes, !scopes.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        components.queryItems = queryItems

        guard let authURL = components.url else {
            throw OAuth2Error.invalidAuthorizationURL
        }

        // Open the browser
        #if canImport(AppKit) || canImport(UIKit)
        await openURLInBrowser(authURL)
        #endif

        // Start a temporary HTTP server to receive the callback
        let code = try await waitForCallback(port: port, expectedState: state)

        // Exchange the authorization code for tokens
        let token = try await exchangeCode(code, tokenUrl: tokenUrl, port: port)

        // Save to Keychain
        await keychain.saveOAuth2Token(
            key: config.keychainKey,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt
        )

        return token
    }

    /// Refresh an expired token using its refresh token.
    public func refreshToken(_ token: OAuth2Token) async throws -> OAuth2Token {
        guard let refreshTokenValue = token.refreshToken else {
            throw OAuth2Error.refreshFailed("No refresh token available")
        }

        let refreshEndpoint = config.refreshUrl ?? config.tokenUrl
        guard let refreshUrl = refreshEndpoint else {
            throw OAuth2Error.missingConfiguration("refreshUrl or tokenUrl")
        }

        let bodyString = [
            "grant_type=refresh_token",
            "refresh_token=\(urlEncode(refreshTokenValue))",
        ].joined(separator: "&")

        guard let url = URL(string: refreshUrl) else {
            throw OAuth2Error.refreshFailed("Invalid refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OAuth2Error.refreshFailed("HTTP \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAt: Date? = tokenResponse.expiresIn.map {
            Date().addingTimeInterval(TimeInterval($0))
        }

        let newToken = OAuth2Token(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? token.refreshToken,
            expiresAt: expiresAt
        )

        await keychain.saveOAuth2Token(
            key: config.keychainKey,
            accessToken: newToken.accessToken,
            refreshToken: newToken.refreshToken,
            expiresAt: newToken.expiresAt
        )

        return newToken
    }

    /// Get a valid access token string. Loads from Keychain and refreshes if expired.
    public func getValidToken() async throws -> String {
        guard let token = await keychain.loadOAuth2Token(key: config.keychainKey) else {
            throw OAuth2Error.noTokenAvailable
        }

        if token.isExpired {
            let refreshed = try await refreshToken(token)
            return refreshed.accessToken
        }

        return token.accessToken
    }

    // MARK: - Build Authorization URL (for testing)

    /// Builds the authorization URL with the given state. Exposed for testability.
    public func buildAuthorizationURL(state: String) throws -> URL {
        guard let authorizeUrl = config.authorizeUrl else {
            throw OAuth2Error.missingConfiguration("authorizeUrl")
        }
        let port = config.callbackPort ?? 8080

        guard var components = URLComponents(string: authorizeUrl) else {
            throw OAuth2Error.invalidAuthorizationURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "response_type", value: "code"))
        queryItems.append(URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)/callback"))
        queryItems.append(URLQueryItem(name: "state", value: state))
        if let scopes = config.scopes, !scopes.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw OAuth2Error.invalidAuthorizationURL
        }
        return url
    }

    // MARK: - Private

    /// URL-encode a string for use in form bodies.
    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    /// Wait for the OAuth2 callback on a temporary local HTTP server.
    private func waitForCallback(port: Int, expectedState: String) async throws -> String {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw OAuth2Error.callbackServerFailed("Could not create socket")
        }

        // Allow port reuse
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw OAuth2Error.callbackServerFailed("Could not bind to port \(port)")
        }

        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw OAuth2Error.callbackServerFailed("Could not listen on port \(port)")
        }

        // Accept one connection (blocking — wrapped in a Task to not block the actor)
        let code: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(socketFD, sockPtr, &clientAddrLen)
                    }
                }
                defer {
                    close(clientFD)
                    close(socketFD)
                }

                guard clientFD >= 0 else {
                    continuation.resume(throwing: OAuth2Error.callbackServerFailed("Accept failed"))
                    return
                }

                // Read the HTTP request
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
                guard bytesRead > 0 else {
                    continuation.resume(throwing: OAuth2Error.callbackServerFailed("No data received"))
                    return
                }
                let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

                // Parse the request line to extract query parameters
                // Example: GET /callback?code=abc&state=xyz HTTP/1.1
                guard let requestLine = requestString.components(separatedBy: "\r\n").first,
                      let pathPart = requestLine.components(separatedBy: " ").dropFirst().first,
                      let urlComponents = URLComponents(string: "http://localhost\(pathPart)") else {
                    // Send error response
                    let errorResponse = Self.buildHTTPResponse(
                        body: "<html><body><h2>Authorization Failed</h2><p>Could not parse callback.</p></body></html>"
                    )
                    _ = send(clientFD, errorResponse, errorResponse.count, 0)
                    continuation.resume(throwing: OAuth2Error.authorizationFailed("Could not parse callback URL"))
                    return
                }

                let queryItems = urlComponents.queryItems ?? []
                let receivedCode = queryItems.first(where: { $0.name == "code" })?.value
                let receivedState = queryItems.first(where: { $0.name == "state" })?.value
                let errorParam = queryItems.first(where: { $0.name == "error" })?.value

                if let errorParam {
                    let errorResponse = Self.buildHTTPResponse(
                        body: "<html><body><h2>Authorization Failed</h2><p>\(errorParam)</p></body></html>"
                    )
                    _ = send(clientFD, errorResponse, errorResponse.count, 0)
                    continuation.resume(throwing: OAuth2Error.authorizationFailed(errorParam))
                    return
                }

                guard let code = receivedCode else {
                    let errorResponse = Self.buildHTTPResponse(
                        body: "<html><body><h2>Authorization Failed</h2><p>No authorization code received.</p></body></html>"
                    )
                    _ = send(clientFD, errorResponse, errorResponse.count, 0)
                    continuation.resume(throwing: OAuth2Error.authorizationFailed("No authorization code in callback"))
                    return
                }

                guard receivedState == expectedState else {
                    let errorResponse = Self.buildHTTPResponse(
                        body: "<html><body><h2>Authorization Failed</h2><p>State mismatch.</p></body></html>"
                    )
                    _ = send(clientFD, errorResponse, errorResponse.count, 0)
                    continuation.resume(throwing: OAuth2Error.stateMismatch)
                    return
                }

                // Send success response
                let successResponse = Self.buildHTTPResponse(
                    body: "<html><body><h2>Authorized!</h2><p>You can close this window.</p></body></html>"
                )
                _ = send(clientFD, successResponse, successResponse.count, 0)

                continuation.resume(returning: code)
            }
        }

        return code
    }

    /// Build a minimal HTTP/1.1 200 response with an HTML body.
    private static func buildHTTPResponse(body: String) -> String {
        let contentLength = body.utf8.count
        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(contentLength)\r
        Connection: close\r
        \r
        \(body)
        """
    }

    /// Exchange an authorization code for an access token.
    private func exchangeCode(_ code: String, tokenUrl: String, port: Int) async throws -> OAuth2Token {
        let bodyString = [
            "grant_type=authorization_code",
            "code=\(urlEncode(code))",
            "redirect_uri=\(urlEncode("http://localhost:\(port)/callback"))",
        ].joined(separator: "&")

        guard let url = URL(string: tokenUrl) else {
            throw OAuth2Error.tokenExchangeFailed("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OAuth2Error.tokenExchangeFailed("HTTP \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAt: Date? = tokenResponse.expiresIn.map {
            Date().addingTimeInterval(TimeInterval($0))
        }

        return OAuth2Token(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: expiresAt
        )
    }

    #if canImport(AppKit)
    /// Open a URL in the default browser.
    @MainActor
    private func openURLInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
    #elseif canImport(UIKit)
    @MainActor
    private func openURLInBrowser(_ url: URL) {
        UIApplication.shared.open(url)
    }
    #endif
}

// MARK: - Token Response DTO

/// JSON structure returned by OAuth2 token endpoints.
private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
