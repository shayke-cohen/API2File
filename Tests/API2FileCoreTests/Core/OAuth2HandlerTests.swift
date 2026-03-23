import XCTest
@testable import API2FileCore

final class OAuth2HandlerTests: XCTestCase {

    // MARK: - Helpers

    /// Build an AuthConfig with OAuth2 fields pre-populated.
    private func makeOAuth2Config(
        authorizeUrl: String = "https://example.com/authorize",
        tokenUrl: String = "https://example.com/token",
        refreshUrl: String? = "https://example.com/refresh",
        scopes: [String]? = ["read", "write"],
        callbackPort: Int = 9876
    ) -> AuthConfig {
        AuthConfig(
            type: .oauth2,
            keychainKey: "test.oauth2handler",
            authorizeUrl: authorizeUrl,
            tokenUrl: tokenUrl,
            refreshUrl: refreshUrl,
            scopes: scopes,
            callbackPort: callbackPort
        )
    }

    // MARK: - Authorization URL Construction

    func testBuildAuthorizationURLContainsRequiredParams() async throws {
        let config = makeOAuth2Config()
        let handler = OAuth2Handler(config: config)
        let state = "test-state-123"

        let url = try await handler.buildAuthorizationURL(state: state)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        // response_type=code
        let responseType = queryItems.first(where: { $0.name == "response_type" })?.value
        XCTAssertEqual(responseType, "code")

        // redirect_uri contains the callback port
        let redirectURI = queryItems.first(where: { $0.name == "redirect_uri" })?.value
        XCTAssertEqual(redirectURI, "http://localhost:9876/callback")

        // state parameter
        let stateParam = queryItems.first(where: { $0.name == "state" })?.value
        XCTAssertEqual(stateParam, state)

        // base URL
        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "example.com")
        XCTAssertEqual(components?.path, "/authorize")
    }

    func testBuildAuthorizationURLIncludesScopes() async throws {
        let config = makeOAuth2Config(scopes: ["read", "write", "admin"])
        let handler = OAuth2Handler(config: config)

        let url = try await handler.buildAuthorizationURL(state: "s")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let scope = queryItems.first(where: { $0.name == "scope" })?.value
        XCTAssertEqual(scope, "read write admin")
    }

    func testBuildAuthorizationURLOmitsScopeWhenEmpty() async throws {
        let config = makeOAuth2Config(scopes: [])
        let handler = OAuth2Handler(config: config)

        let url = try await handler.buildAuthorizationURL(state: "s")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let scope = queryItems.first(where: { $0.name == "scope" })
        XCTAssertNil(scope, "scope query item should be absent when scopes list is empty")
    }

    func testBuildAuthorizationURLOmitsScopeWhenNil() async throws {
        let config = makeOAuth2Config(scopes: nil)
        let handler = OAuth2Handler(config: config)

        let url = try await handler.buildAuthorizationURL(state: "s")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let scope = queryItems.first(where: { $0.name == "scope" })
        XCTAssertNil(scope, "scope query item should be absent when scopes is nil")
    }

    func testBuildAuthorizationURLUsesDefaultPortWhenNil() async throws {
        let config = AuthConfig(
            type: .oauth2,
            keychainKey: "test",
            authorizeUrl: "https://example.com/auth",
            tokenUrl: "https://example.com/token",
            callbackPort: nil
        )
        let handler = OAuth2Handler(config: config)

        let url = try await handler.buildAuthorizationURL(state: "s")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let redirectURI = queryItems.first(where: { $0.name == "redirect_uri" })?.value
        XCTAssertEqual(redirectURI, "http://localhost:8080/callback")
    }

    func testBuildAuthorizationURLThrowsWhenAuthorizeUrlMissing() async {
        let config = AuthConfig(
            type: .oauth2,
            keychainKey: "test",
            authorizeUrl: nil,
            tokenUrl: "https://example.com/token"
        )
        let handler = OAuth2Handler(config: config)

        do {
            _ = try await handler.buildAuthorizationURL(state: "s")
            XCTFail("Expected OAuth2Error.missingConfiguration")
        } catch let error as OAuth2Error {
            if case .missingConfiguration(let field) = error {
                XCTAssertEqual(field, "authorizeUrl")
            } else {
                XCTFail("Expected missingConfiguration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - getValidToken

    func testGetValidTokenReturnsCachedTokenWhenNotExpired() async throws {
        let keychain = KeychainManager()
        let config = makeOAuth2Config()

        // Store a token that expires in 1 hour
        let futureExpiry = Date().addingTimeInterval(3600)
        await keychain.saveOAuth2Token(
            key: config.keychainKey,
            accessToken: "cached-access-token",
            refreshToken: "cached-refresh-token",
            expiresAt: futureExpiry
        )

        let handler = OAuth2Handler(config: config, keychain: keychain)
        let token = try await handler.getValidToken()
        XCTAssertEqual(token, "cached-access-token")

        // Clean up
        await keychain.delete(key: config.keychainKey)
    }

    func testGetValidTokenThrowsWhenNoTokenStored() async {
        let keychain = KeychainManager()
        let config = makeOAuth2Config()

        // Ensure no token is stored
        await keychain.delete(key: config.keychainKey)

        let handler = OAuth2Handler(config: config, keychain: keychain)

        do {
            _ = try await handler.getValidToken()
            XCTFail("Expected OAuth2Error.noTokenAvailable")
        } catch let error as OAuth2Error {
            if case .noTokenAvailable = error {
                // Expected
            } else {
                XCTFail("Expected noTokenAvailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - OAuth2Token expiry

    func testOAuth2TokenIsExpiredWhenPastExpiry() {
        let expired = OAuth2Token(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(-120)
        )
        XCTAssertTrue(expired.isExpired)
    }

    func testOAuth2TokenIsNotExpiredWhenFutureExpiry() {
        let valid = OAuth2Token(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(valid.isExpired)
    }

    func testOAuth2TokenIsNotExpiredWhenNoExpiry() {
        let noExpiry = OAuth2Token(
            accessToken: "a",
            refreshToken: nil,
            expiresAt: nil
        )
        XCTAssertFalse(noExpiry.isExpired)
    }

    // MARK: - OAuth2Error descriptions

    func testOAuth2ErrorDescriptions() {
        let errors: [(OAuth2Error, String)] = [
            (.missingConfiguration("tokenUrl"), "OAuth2 configuration missing required field: tokenUrl"),
            (.invalidAuthorizationURL, "Failed to construct a valid authorization URL."),
            (.noTokenAvailable, "No OAuth2 token available. Please authenticate first."),
            (.stateMismatch, "OAuth2 state parameter mismatch — possible CSRF attack."),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }
}
