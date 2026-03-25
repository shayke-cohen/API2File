import XCTest
@testable import API2FileCore

/// Tests the `enabled` and `siteUrl` fields on AdapterConfig.
final class AdapterEnableDisableTests: XCTestCase {

    func testEnabledDefaultsToNil() throws {
        let json = """
        {
            "service": "test",
            "displayName": "Test",
            "version": "1.0",
            "auth": {"type": "bearer", "keychainKey": "test.key"},
            "resources": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AdapterConfig.self, from: json)
        XCTAssertNil(config.enabled, "enabled should be nil when not present (treated as true)")
        XCTAssertNil(config.siteUrl, "siteUrl should be nil when not present")
    }

    func testEnabledFalseDecodes() throws {
        let json = """
        {
            "service": "test",
            "displayName": "Test",
            "version": "1.0",
            "auth": {"type": "bearer", "keychainKey": "test.key"},
            "resources": [],
            "enabled": false
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AdapterConfig.self, from: json)
        XCTAssertEqual(config.enabled, false)
    }

    func testSiteUrlDecodes() throws {
        let json = """
        {
            "service": "test",
            "displayName": "Test",
            "version": "1.0",
            "auth": {"type": "bearer", "keychainKey": "test.key"},
            "resources": [],
            "siteUrl": "https://example.com/dashboard"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AdapterConfig.self, from: json)
        XCTAssertEqual(config.siteUrl, "https://example.com/dashboard")
    }

    func testBackwardCompatibility() throws {
        // All bundled adapter JSONs must decode without errors
        // even though they were created before enabled/siteUrl fields existed
        guard let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil) else {
            XCTFail("Could not find Resources bundle")
            return
        }
        let adaptersDir = resourceURL.appendingPathComponent("Adapters")
        let files = try FileManager.default.contentsOfDirectory(at: adaptersDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("adapter") }

        XCTAssertGreaterThanOrEqual(files.count, 12, "Should find at least 12 bundled adapters")

        for file in files {
            let data = try Data(contentsOf: file)
            do {
                let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
                XCTAssertFalse(config.service.isEmpty, "Service ID should not be empty in \(file.lastPathComponent)")
            } catch {
                XCTFail("Failed to decode \(file.lastPathComponent): \(error)")
            }
        }
    }
}
