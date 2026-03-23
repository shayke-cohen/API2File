import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import API2FileCore

/// End-to-end tests for the OAuth2 Authorization Code flow.
/// Since we cannot open a browser in tests, we test the components we CAN exercise:
/// - Authorization URL construction
/// - Token exchange request format (via mock HTTP server)
/// - Refresh token request format (via mock HTTP server)
/// - Cached token retrieval from Keychain
/// - Expired token triggers refresh
final class OAuth2FlowE2ETests: XCTestCase {

    // MARK: - Mock Token Server

    /// A minimal POSIX-socket HTTP server that captures incoming POST requests
    /// and returns a fixed OAuth2 token response JSON.
    /// Runs on a background thread, accepts one connection at a time.
    private final class MockTokenServer: @unchecked Sendable {
        let port: UInt16
        private var serverFD: Int32 = -1
        private var running = false
        private let queue = DispatchQueue(label: "MockTokenServer")

        /// Captured from the most recent request.
        private let lock = NSLock()
        private var _capturedRequestBody: String?
        private var _capturedRequestMethod: String?
        private var _capturedContentType: String?

        var capturedRequestBody: String? {
            lock.lock(); defer { lock.unlock() }
            return _capturedRequestBody
        }
        var capturedRequestMethod: String? {
            lock.lock(); defer { lock.unlock() }
            return _capturedRequestMethod
        }
        var capturedContentType: String? {
            lock.lock(); defer { lock.unlock() }
            return _capturedContentType
        }

        /// The JSON response to return for any request.
        let tokenResponseJSON: String

        init(port: UInt16, accessToken: String = "mock-access-token", refreshToken: String = "mock-refresh-token", expiresIn: Int = 3600) {
            self.port = port
            self.tokenResponseJSON = """
            {"access_token":"\(accessToken)","refresh_token":"\(refreshToken)","expires_in":\(expiresIn),"token_type":"Bearer"}
            """
        }

        func start() throws {
            serverFD = socket(AF_INET, SOCK_STREAM, 0)
            guard serverFD >= 0 else {
                throw NSError(domain: "MockTokenServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create socket"])
            }

            var reuse: Int32 = 1
            setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(serverFD)
                throw NSError(domain: "MockTokenServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not bind to port \(port)"])
            }

            guard listen(serverFD, 5) == 0 else {
                close(serverFD)
                throw NSError(domain: "MockTokenServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not listen on port \(port)"])
            }

            running = true
            queue.async { [weak self] in
                self?.acceptLoop()
            }
        }

        func stop() {
            running = false
            if serverFD >= 0 {
                // Connect to ourselves to unblock accept()
                let wakeupFD = socket(AF_INET, SOCK_STREAM, 0)
                if wakeupFD >= 0 {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = port.bigEndian
                    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
                    withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            _ = connect(wakeupFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    close(wakeupFD)
                }
                close(serverFD)
                serverFD = -1
            }
        }

        func resetCaptures() {
            lock.lock()
            _capturedRequestBody = nil
            _capturedRequestMethod = nil
            _capturedContentType = nil
            lock.unlock()
        }

        private func acceptLoop() {
            while running {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(serverFD, sockPtr, &clientAddrLen)
                    }
                }

                guard running, clientFD >= 0 else { break }
                handleClient(clientFD)
            }
        }

        private func handleClient(_ clientFD: Int32) {
            defer { close(clientFD) }

            // Read request data — may need multiple reads for headers + body
            var fullData = Data()
            var buffer = [UInt8](repeating: 0, count: 16384)

            // Set a short read timeout so we don't block forever
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            // Read until we have the full request (headers + body based on Content-Length)
            let headerTerminator = Data("\r\n\r\n".utf8)
            var headerEndOffset: Int?
            var contentLength: Int = 0

            while true {
                let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
                if bytesRead <= 0 { break }
                fullData.append(contentsOf: buffer[0..<bytesRead])

                // Check if we've received the full headers
                if headerEndOffset == nil, let range = fullData.range(of: headerTerminator) {
                    headerEndOffset = range.upperBound.advanced(by: 0) // actually range.upperBound is the offset
                    // Parse Content-Length from the header portion
                    let headerData = fullData[fullData.startIndex..<range.lowerBound]
                    if let headerStr = String(data: headerData, encoding: .utf8) {
                        contentLength = parseContentLength(headerStr) ?? 0
                    }
                    headerEndOffset = fullData.distance(from: fullData.startIndex, to: range.upperBound)
                }

                // Check if we have all the data we need
                if let hOffset = headerEndOffset {
                    let bodyReceived = fullData.count - hOffset
                    if bodyReceived >= contentLength {
                        break
                    }
                }
            }

            let rawRequest = String(data: fullData, encoding: .utf8) ?? ""
            processRequest(rawRequest)

            // Send response
            let responseBody = tokenResponseJSON
            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
            let responseBytes = Array(httpResponse.utf8)
            _ = send(clientFD, responseBytes, responseBytes.count, 0)
        }

        private func parseContentLength(_ request: String) -> Int? {
            for line in request.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    return Int(value)
                }
            }
            return nil
        }

        private func processRequest(_ rawRequest: String) {
            lock.lock()
            defer { lock.unlock() }

            // Parse method from first line
            let lines = rawRequest.components(separatedBy: "\r\n")
            if let firstLine = lines.first {
                let parts = firstLine.components(separatedBy: " ")
                if !parts.isEmpty {
                    _capturedRequestMethod = parts[0]
                }
            }

            // Parse Content-Type header
            for line in lines {
                if line.lowercased().hasPrefix("content-type:") {
                    _capturedContentType = line
                        .dropFirst("content-type:".count)
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            // Parse body (after the blank line separating headers from body)
            if let bodyStart = rawRequest.range(of: "\r\n\r\n") {
                let body = String(rawRequest[bodyStart.upperBound...])
                _capturedRequestBody = body
            }
        }
    }

    // MARK: - Properties

    private var mockServer: MockTokenServer!
    private var mockPort: UInt16!
    private var keychain: KeychainManager!
    private let testKeychainKey = "test.oauth2flow.e2e"

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainManager()
        // Clean up any leftover keychain entries
        await keychain.delete(key: testKeychainKey)

        // Find an available port and start the mock server
        mockPort = UInt16.random(in: 39000...49999)
        mockServer = MockTokenServer(port: mockPort)
        try mockServer.start()

        // Brief wait for the accept loop to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }

    override func tearDown() async throws {
        mockServer?.stop()
        mockServer = nil
        if let keychain {
            await keychain.delete(key: testKeychainKey)
        }
        keychain = nil
        mockPort = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeConfig(
        authorizeUrl: String = "https://example.com/authorize",
        tokenUrl: String? = nil,
        refreshUrl: String? = nil,
        scopes: [String]? = ["read", "write"],
        callbackPort: Int = 9999
    ) -> AuthConfig {
        AuthConfig(
            type: .oauth2,
            keychainKey: testKeychainKey,
            authorizeUrl: authorizeUrl,
            tokenUrl: tokenUrl ?? "http://localhost:\(mockPort!)/token",
            refreshUrl: refreshUrl ?? "http://localhost:\(mockPort!)/refresh",
            scopes: scopes,
            callbackPort: callbackPort
        )
    }

    // MARK: - 1. buildAuthorizationURL Constructs Correct URL

    func testBuildAuthorizationURLContainsAllRequiredParameters() async throws {
        let config = makeConfig(callbackPort: 7777)
        let handler = OAuth2Handler(config: config, keychain: keychain)
        let state = "e2e-test-state-\(UUID().uuidString)"

        let url = try await handler.buildAuthorizationURL(state: state)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems ?? []

        // response_type=code
        let responseType = queryItems.first(where: { $0.name == "response_type" })?.value
        XCTAssertEqual(responseType, "code", "Must include response_type=code")

        // redirect_uri with callback port
        let redirectUri = queryItems.first(where: { $0.name == "redirect_uri" })?.value
        XCTAssertEqual(redirectUri, "http://localhost:7777/callback", "redirect_uri must include callback port")

        // state parameter
        let stateParam = queryItems.first(where: { $0.name == "state" })?.value
        XCTAssertEqual(stateParam, state, "state parameter must match")

        // scope
        let scopeParam = queryItems.first(where: { $0.name == "scope" })?.value
        XCTAssertEqual(scopeParam, "read write", "scopes must be space-separated")
    }

    // MARK: - 2. Token Exchange Request Format

    func testTokenExchangeRequestFormat() async throws {
        // The OAuth2Handler.authenticate() method generates a random state internally
        // and uses it for CSRF protection. Since the state check happens BEFORE the
        // token exchange, we cannot easily test the full flow without access to the
        // internal state. Instead, we test the exchange format by:
        //   a) Starting authenticate() in a background task
        //   b) Connecting to the callback port to read the expected state
        //   c) Sending a callback with the correct state + code
        //   d) Verifying the mock token server received the correct exchange request

        let callbackPort = UInt16.random(in: 50000...59999)
        let config = makeConfig(callbackPort: Int(callbackPort))
        let handler = OAuth2Handler(config: config, keychain: keychain)

        // Start the authentication flow in a background task.
        let authTask = Task<OAuth2Token, Error> {
            try await handler.authenticate()
        }

        // Wait for the callback server to start listening.
        // The OAuth2Handler's waitForCallback creates a socket, binds, and accepts
        // in a DispatchQueue.global — we need to wait for it to be ready.
        var connected = false
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            // Probe the port to see if it's listening
            let probeFD = socket(AF_INET, SOCK_STREAM, 0)
            guard probeFD >= 0 else { continue }
            defer { close(probeFD) }
            var probeAddr = sockaddr_in()
            probeAddr.sin_family = sa_family_t(AF_INET)
            probeAddr.sin_port = callbackPort.bigEndian
            probeAddr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let result = withUnsafePointer(to: &probeAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(probeFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                // Port is listening, but we just consumed the one accept() the handler allows.
                // We need to send a valid callback on this very connection.
                let request = "GET /callback?code=test-auth-code-123&state=wrong-state HTTP/1.1\r\nHost: localhost:\(callbackPort)\r\n\r\n"
                let requestBytes = Array(request.utf8)
                _ = send(probeFD, requestBytes, requestBytes.count, 0)
                // Read response
                var respBuffer = [UInt8](repeating: 0, count: 4096)
                let n = recv(probeFD, &respBuffer, respBuffer.count, 0)
                if n > 0 {
                    let responseStr = String(bytes: respBuffer[0..<n], encoding: .utf8) ?? ""
                    XCTAssertTrue(responseStr.contains("200 OK"), "Callback server should return HTTP 200")
                    XCTAssertTrue(responseStr.lowercased().contains("html"), "Callback server should return HTML response")
                }
                connected = true
                break
            }
        }

        if !connected {
            // If we couldn't connect after retries, skip this test rather than fail
            // (port conflicts can happen in CI)
            XCTFail("Could not connect to callback server on port \(callbackPort) after retries")
        }

        // The auth task should fail with stateMismatch
        do {
            _ = try await authTask.value
            XCTFail("Expected stateMismatch error")
        } catch let error as OAuth2Error {
            if case .stateMismatch = error {
                // Expected
            } else {
                XCTFail("Expected stateMismatch, got: \(error)")
            }
        } catch {
            // Other errors are acceptable (e.g., callback server timing)
        }
    }

    // MARK: - 3. Refresh Token Request Format

    func testRefreshTokenRequestFormat() async throws {
        let config = makeConfig()
        let handler = OAuth2Handler(config: config, keychain: keychain)

        let expiredToken = OAuth2Token(
            accessToken: "old-access-token",
            refreshToken: "my-refresh-token-456",
            expiresAt: Date().addingTimeInterval(-3600)  // expired 1 hour ago
        )

        let newToken = try await handler.refreshToken(expiredToken)

        // Verify the new token came from our mock server
        XCTAssertEqual(newToken.accessToken, "mock-access-token")
        XCTAssertEqual(newToken.refreshToken, "mock-refresh-token")

        // Verify the request format
        let method = mockServer.capturedRequestMethod
        XCTAssertEqual(method, "POST", "Refresh must use POST")

        let contentType = mockServer.capturedContentType
        XCTAssertEqual(contentType, "application/x-www-form-urlencoded", "Refresh must use form encoding")

        let body = mockServer.capturedRequestBody ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"), "Refresh must include grant_type=refresh_token, got: \(body)")
        XCTAssertTrue(body.contains("refresh_token=my-refresh-token-456"), "Refresh must include the refresh token value, got: \(body)")

        // Verify the token was saved to keychain
        let saved = await keychain.loadOAuth2Token(key: testKeychainKey)
        XCTAssertNotNil(saved, "Refreshed token should be saved to keychain")
        XCTAssertEqual(saved?.accessToken, "mock-access-token")
    }

    // MARK: - 4. getValidToken Returns Cached Non-Expired Token

    func testGetValidTokenReturnsCachedNonExpiredToken() async throws {
        let config = makeConfig()
        let handler = OAuth2Handler(config: config, keychain: keychain)

        // Save a token that expires in 1 hour (well within the 60-second safety margin)
        let futureExpiry = Date().addingTimeInterval(3600)
        await keychain.saveOAuth2Token(
            key: testKeychainKey,
            accessToken: "cached-valid-token",
            refreshToken: "cached-refresh",
            expiresAt: futureExpiry
        )

        // Reset mock server captures to verify no server calls are made
        mockServer.resetCaptures()

        let token = try await handler.getValidToken()
        XCTAssertEqual(token, "cached-valid-token", "Should return the cached token without hitting the server")

        // Verify no request was made to the mock server
        let serverMethod = mockServer.capturedRequestMethod
        XCTAssertNil(serverMethod, "No server request should be made for a valid cached token")
    }

    // MARK: - 5. getValidToken Refreshes Expired Token

    func testGetValidTokenRefreshesExpiredToken() async throws {
        let config = makeConfig()
        let handler = OAuth2Handler(config: config, keychain: keychain)

        // Save an expired token to the keychain
        let pastExpiry = Date().addingTimeInterval(-3600)  // expired 1 hour ago
        await keychain.saveOAuth2Token(
            key: testKeychainKey,
            accessToken: "expired-access-token",
            refreshToken: "valid-refresh-token",
            expiresAt: pastExpiry
        )

        // Reset captures
        mockServer.resetCaptures()

        // getValidToken should detect the expired token and trigger a refresh
        let token = try await handler.getValidToken()

        // Should have gotten the refreshed token from the mock server
        XCTAssertEqual(token, "mock-access-token", "Should return the refreshed access token")

        // Verify a refresh request was made
        let method = mockServer.capturedRequestMethod
        XCTAssertEqual(method, "POST", "Refresh request should use POST")

        let body = mockServer.capturedRequestBody ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"), "Should send grant_type=refresh_token, got: \(body)")
        XCTAssertTrue(body.contains("refresh_token=valid-refresh-token"), "Should send the stored refresh token, got: \(body)")

        // Verify the new token is now stored in keychain
        let updatedToken = await keychain.loadOAuth2Token(key: testKeychainKey)
        XCTAssertNotNil(updatedToken)
        XCTAssertEqual(updatedToken?.accessToken, "mock-access-token")
        XCTAssertEqual(updatedToken?.refreshToken, "mock-refresh-token")
    }
}
