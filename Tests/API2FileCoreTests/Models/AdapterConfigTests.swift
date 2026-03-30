import XCTest
@testable import API2FileCore

final class AdapterConfigTests: XCTestCase {

    func testDecodeMinimalConfig() throws {
        let json = """
        {
            "service": "test",
            "displayName": "Test Service",
            "version": "1.0",
            "auth": {
                "type": "bearer",
                "keychainKey": "api2file.test.key"
            },
            "resources": [
                {
                    "name": "items",
                    "pull": {
                        "url": "https://api.test.com/items"
                    },
                    "fileMapping": {
                        "strategy": "one-per-record",
                        "directory": "items",
                        "format": "json"
                    }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)

        XCTAssertEqual(config.service, "test")
        XCTAssertEqual(config.displayName, "Test Service")
        XCTAssertEqual(config.auth.type, .bearer)
        XCTAssertEqual(config.resources.count, 1)
        XCTAssertEqual(config.resources[0].name, "items")
        XCTAssertEqual(config.resources[0].fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(config.resources[0].fileMapping.format, .json)
    }

    func testDecodeFullConfig() throws {
        let json = """
        {
            "service": "monday",
            "displayName": "Monday.com",
            "version": "1.0",
            "auth": {
                "type": "bearer",
                "keychainKey": "api2file.monday.key",
                "setup": {
                    "instructions": "Get your API key from monday.com",
                    "url": "https://monday.com/apps/manage"
                }
            },
            "globals": {
                "baseUrl": "https://api.monday.com/v2",
                "method": "POST"
            },
            "resources": [
                {
                    "name": "boards",
                    "pull": {
                        "url": "https://api.monday.com/v2",
                        "type": "graphql",
                        "query": "{ boards { id name } }",
                        "dataPath": "$.data.boards"
                    },
                    "push": {
                        "create": {
                            "url": "https://api.monday.com/v2"
                        },
                        "update": {
                            "url": "https://api.monday.com/v2"
                        }
                    },
                    "fileMapping": {
                        "strategy": "collection",
                        "directory": "boards",
                        "filename": "{name}.csv",
                        "format": "csv",
                        "idField": "id",
                        "transforms": {
                            "pull": [
                                { "op": "pick", "fields": ["id", "name", "state"] }
                            ]
                        }
                    },
                    "sync": {
                        "interval": 60,
                        "debounceMs": 500
                    }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)

        XCTAssertEqual(config.globals?.baseUrl, "https://api.monday.com/v2")
        XCTAssertEqual(config.resources[0].pull?.type, .graphql)
        XCTAssertEqual(config.resources[0].fileMapping.format, .csv)
        XCTAssertEqual(config.resources[0].sync?.intervalSeconds, 60)
        XCTAssertEqual(config.resources[0].fileMapping.transforms?.pull?.count, 1)
        XCTAssertEqual(config.resources[0].fileMapping.transforms?.pull?[0].op, "pick")
    }

    func testSyncStateRoundTrip() throws {
        var state = SyncState()
        state.files["test.json"] = FileSyncState(
            remoteId: "abc-123",
            lastSyncedHash: "sha256:deadbeef",
            lastRemoteETag: "W/\"xyz\"",
            lastSyncTime: Date(timeIntervalSince1970: 1000000),
            status: .synced
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(SyncState.self, from: data)

        XCTAssertEqual(decoded.files["test.json"]?.remoteId, "abc-123")
        XCTAssertEqual(decoded.files["test.json"]?.status, .synced)
    }

    func testDecodeManagedWorkspaceConfigAndCommitPolicy() throws {
        let json = """
        {
            "service": "test",
            "displayName": "Test Service",
            "version": "1.0",
            "storageMode": "managed_workspace",
            "auth": {
                "type": "bearer",
                "keychainKey": "api2file.test.key"
            },
            "resources": [
                {
                    "name": "items",
                    "commitPolicy": "push-then-commit",
                    "pull": {
                        "url": "https://api.test.com/items"
                    },
                    "push": {
                        "update": {
                            "url": "https://api.test.com/items/{id}"
                        }
                    },
                    "fileMapping": {
                        "strategy": "collection",
                        "directory": ".",
                        "filename": "items.csv",
                        "format": "csv",
                        "idField": "id"
                    }
                }
            ]
        }
        """
        let config = try JSONDecoder().decode(AdapterConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.storageMode, .managedWorkspace)
        XCTAssertEqual(config.resources[0].commitPolicy, .pushThenCommit)
        XCTAssertEqual(config.resources[0].effectiveManagedCommitPolicy, .pushThenCommit)
    }

    func testEffectiveManagedCommitPolicyDefaultsToValidateThenCommitForReadOnlyResources() {
        let resource = ResourceConfig(
            name: "items",
            fileMapping: FileMappingConfig(
                strategy: .collection,
                directory: ".",
                filename: "items.csv",
                format: .csv,
                readOnly: true
            )
        )

        XCTAssertEqual(resource.effectiveManagedCommitPolicy, .validateThenCommit)
    }
}
