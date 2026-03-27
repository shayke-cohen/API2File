import XCTest
@testable import API2FileCore

final class AdapterStoreTests: XCTestCase {

    func testRefreshInstalledWixAdapterPreservesResolvedSetupValues() async throws {
        try await AdapterStore.shared.seedIfNeeded()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let legacyAdapter = """
        {
          "service": "wix",
          "displayName": "Wix",
          "version": "1.0",
          "auth": {
            "type": "apiKey",
            "keychainKey": "api2file.wix.key",
            "setup": {
              "instructions": "Legacy setup",
              "url": "https://manage.wix.com/account/api-keys"
            }
          },
          "enabled": true,
          "siteUrl": "https://example.wixsite.com/live-site",
          "globals": {
            "baseUrl": "https://www.wixapis.com",
            "headers": {
              "Content-Type": "application/json",
              "wix-site-id": "site-12345"
            }
          },
          "resources": [
            {
              "name": "contacts",
              "description": "Legacy contacts",
              "dashboardUrl": "https://manage.wix.com/dashboard/site-12345/contacts",
              "pull": {
                "method": "POST",
                "url": "https://www.wixapis.com/contacts/v4/contacts/query",
                "dataPath": "$.contacts"
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "contacts.csv",
                "format": "csv",
                "idField": "id"
              }
            }
          ]
        }
        """

        try legacyAdapter.data(using: .utf8)?.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            options: .atomic
        )

        let refreshed = try await AdapterStore.shared.refreshInstalledAdapterIfNeeded(serviceDir: tempDir)
        XCTAssertTrue(refreshed, "Expected older deployed Wix adapter to be refreshed from a newer template")

        let config = try AdapterEngine.loadConfig(from: tempDir)
        XCTAssertEqual(config.service, "wix")
        XCTAssertEqual(config.globals?.headers?["wix-site-id"], "site-12345")
        XCTAssertEqual(config.siteUrl, "https://example.wixsite.com/live-site")
        XCTAssertEqual(config.enabled, true)
        XCTAssertEqual(config.setupFields?.map(\.key), ["wix-site-id", "wix-site-url"])
        XCTAssertTrue(config.resources.count > 1, "Expected refreshed adapter to restore the full Wix resource set")
    }

    func testRefreshInstalledWixAdapterPreservesDeployedOnlyResources() async throws {
        try await AdapterStore.shared.seedIfNeeded()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let legacyAdapter = """
        {
          "service": "wix",
          "displayName": "Wix",
          "version": "1.0",
          "auth": {
            "type": "apiKey",
            "keychainKey": "api2file.wix.key"
          },
          "siteUrl": "https://example.wixsite.com/live-site",
          "globals": {
            "baseUrl": "https://www.wixapis.com",
            "headers": {
              "Content-Type": "application/json",
              "wix-site-id": "site-12345"
            }
          },
          "resources": [
            {
              "name": "contacts",
              "pull": {
                "url": "https://www.wixapis.com/contacts/v4/contacts/query"
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "contacts.csv",
                "format": "csv"
              }
            },
            {
              "name": "cms-projects",
              "pull": {
                "url": "https://www.wixapis.com/wix-data/v2/items/query"
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "cms-projects.csv",
                "format": "csv"
              }
            }
          ]
        }
        """

        try legacyAdapter.data(using: .utf8)?.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            options: .atomic
        )

        let refreshed = try await AdapterStore.shared.refreshInstalledAdapterIfNeeded(serviceDir: tempDir)
        XCTAssertTrue(refreshed, "Expected older deployed Wix adapter to be refreshed from a newer template")

        let config = try AdapterEngine.loadConfig(from: tempDir)
        XCTAssertTrue(
            config.resources.contains(where: { $0.name == "cms-projects" }),
            "Refreshing a deployed adapter should preserve deployed-only Wix resources"
        )
    }
}
