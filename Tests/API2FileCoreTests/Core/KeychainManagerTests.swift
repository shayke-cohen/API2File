import XCTest
@testable import API2FileCore

final class KeychainManagerTests: XCTestCase {

    private var manager: KeychainManager!

    override func setUp() async throws {
        manager = KeychainManager()
        // Clean up any leftover test keys.
        await manager.delete(key: "test.key")
        await manager.delete(key: "test.overwrite")
        await manager.delete(key: "test.oauth2")
        await manager.delete(key: "test.nonexistent")
    }

    override func tearDown() async throws {
        // Clean up after each test.
        await manager.delete(key: "test.key")
        await manager.delete(key: "test.overwrite")
        await manager.delete(key: "test.oauth2")
        await manager.delete(key: "test.nonexistent")
        manager = nil
    }

    // MARK: - String CRUD

    func testSaveAndLoad() async {
        let saved = await manager.save(key: "test.key", value: "my-secret-api-key")
        XCTAssertTrue(saved, "save should succeed")

        let loaded = await manager.load(key: "test.key")
        XCTAssertEqual(loaded, "my-secret-api-key")
    }

    func testLoadNonExistentKeyReturnsNil() async {
        let loaded = await manager.load(key: "test.nonexistent")
        XCTAssertNil(loaded, "loading a key that was never saved should return nil")
    }

    func testOverwriteExistingKey() async {
        let saved1 = await manager.save(key: "test.overwrite", value: "original-value")
        XCTAssertTrue(saved1)

        let saved2 = await manager.save(key: "test.overwrite", value: "updated-value")
        XCTAssertTrue(saved2, "overwrite should succeed")

        let loaded = await manager.load(key: "test.overwrite")
        XCTAssertEqual(loaded, "updated-value")
    }

    func testDeleteExistingKey() async {
        await manager.save(key: "test.key", value: "to-be-deleted")
        let deleted = await manager.delete(key: "test.key")
        XCTAssertTrue(deleted, "delete should succeed for an existing key")

        let loaded = await manager.load(key: "test.key")
        XCTAssertNil(loaded, "load should return nil after deletion")
    }

    func testDeleteNonExistentKey() async {
        let deleted = await manager.delete(key: "test.nonexistent")
        XCTAssertFalse(deleted, "delete should return false for a key that does not exist")
    }

    // MARK: - OAuth2 Token

    func testSaveAndLoadOAuth2Token() async {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let saved = await manager.saveOAuth2Token(
            key: "test.oauth2",
            accessToken: "access-abc",
            refreshToken: "refresh-xyz",
            expiresAt: expiry
        )
        XCTAssertTrue(saved)

        let token = await manager.loadOAuth2Token(key: "test.oauth2")
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.accessToken, "access-abc")
        XCTAssertEqual(token?.refreshToken, "refresh-xyz")
        if let tokenExpiry = token?.expiresAt {
            XCTAssertEqual(tokenExpiry.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1.0)
        } else {
            XCTFail("expiresAt should not be nil")
        }
    }

    func testLoadOAuth2TokenNonExistent() async {
        let token = await manager.loadOAuth2Token(key: "test.nonexistent")
        XCTAssertNil(token)
    }

    func testOAuth2TokenIsExpired() {
        let expiredToken = OAuth2Token(
            accessToken: "expired",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-120)
        )
        XCTAssertTrue(expiredToken.isExpired)

        let validToken = OAuth2Token(
            accessToken: "valid",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(validToken.isExpired)

        let noExpiryToken = OAuth2Token(
            accessToken: "forever",
            refreshToken: nil,
            expiresAt: nil
        )
        XCTAssertFalse(noExpiryToken.isExpired, "token with no expiry should not be considered expired")
    }
}
