import XCTest
@testable import API2FileCore

/// Tests that every real (production) adapter config file in the Resources bundle
/// parses correctly and contains the expected structure for its service.
final class RealAdapterConfigTests: XCTestCase {

    // MARK: - Helpers

    private func loadBundledAdapter(named name: String) throws -> AdapterConfig {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Adapters") else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Adapter \(name) not found in bundle"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AdapterConfig.self, from: data)
    }

    /// All real adapter config file names (without .json extension).
    private static let realAdapterNames = [
        "github.adapter",
        "wix.adapter",
        "monday.adapter",
        "airtable.adapter",
        "demo.adapter",
    ]

    // MARK: - 1. All Configs Parse Correctly

    func testAllRealAdapterConfigsParseSuccessfully() throws {
        for name in Self.realAdapterNames {
            let config = try loadBundledAdapter(named: name)
            XCTAssertFalse(config.service.isEmpty, "\(name): service should not be empty")
            XCTAssertFalse(config.displayName.isEmpty, "\(name): displayName should not be empty")
            XCTAssertFalse(config.version.isEmpty, "\(name): version should not be empty")
        }
    }

    // MARK: - 2. Required Fields Present

    func testAllRealAdaptersHaveRequiredFields() throws {
        for name in Self.realAdapterNames {
            let config = try loadBundledAdapter(named: name)

            // service, displayName, auth, resources are required
            XCTAssertFalse(config.service.isEmpty, "\(name): service must be present")
            XCTAssertFalse(config.displayName.isEmpty, "\(name): displayName must be present")
            XCTAssertFalse(config.auth.keychainKey.isEmpty, "\(name): auth.keychainKey must be present")
            XCTAssertFalse(config.resources.isEmpty, "\(name): resources must not be empty")
        }
    }

    // MARK: - 3. Each Resource Has Valid Pull Config with URL

    func testAllResourcesHaveValidPullConfigWithURL() throws {
        for name in Self.realAdapterNames {
            let config = try loadBundledAdapter(named: name)
            for resource in config.resources {
                XCTAssertNotNil(resource.pull, "\(config.service)/\(resource.name): pull config must be present")
                if let pull = resource.pull {
                    XCTAssertFalse(pull.url.isEmpty, "\(config.service)/\(resource.name): pull.url must not be empty")
                    XCTAssertTrue(
                        pull.url.hasPrefix("http://") || pull.url.hasPrefix("https://"),
                        "\(config.service)/\(resource.name): pull.url must be a valid HTTP(S) URL, got: \(pull.url)"
                    )
                }
            }
        }
    }

    // MARK: - 4. File Mapping Has Valid Strategy and Format

    func testAllResourcesHaveValidFileMappingStrategyAndFormat() throws {
        let validStrategies: Set<MappingStrategy> = [.onePerRecord, .collection, .mirror]
        let validFormats: Set<FileFormat> = [.json, .csv, .html, .markdown, .yaml, .text, .raw, .ics, .vcf, .eml, .svg, .webloc, .xlsx, .docx, .pptx]

        for name in Self.realAdapterNames {
            let config = try loadBundledAdapter(named: name)
            for resource in config.resources {
                let mapping = resource.fileMapping
                XCTAssertTrue(
                    validStrategies.contains(mapping.strategy),
                    "\(config.service)/\(resource.name): strategy '\(mapping.strategy)' is not valid"
                )
                XCTAssertTrue(
                    validFormats.contains(mapping.format),
                    "\(config.service)/\(resource.name): format '\(mapping.format)' is not valid"
                )
                XCTAssertFalse(
                    mapping.directory.isEmpty,
                    "\(config.service)/\(resource.name): fileMapping.directory must not be empty"
                )
            }
        }
    }

    // MARK: - 5. GitHub: Verify Accept Header

    func testGitHubAdapterHasCorrectAcceptHeader() throws {
        let config = try loadBundledAdapter(named: "github.adapter")
        XCTAssertEqual(config.service, "github")

        let acceptHeader = config.globals?.headers?["Accept"]
        XCTAssertEqual(
            acceptHeader,
            "application/vnd.github+json",
            "GitHub adapter must include Accept: application/vnd.github+json header"
        )

        // Also verify the API version header is present
        let apiVersion = config.globals?.headers?["X-GitHub-Api-Version"]
        XCTAssertNotNil(apiVersion, "GitHub adapter should include X-GitHub-Api-Version header")
    }

    // MARK: - 6. Wix: Verify Base URL

    func testWixAdapterHasCorrectBaseURL() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")
        XCTAssertEqual(config.service, "wix")

        let baseUrl = config.globals?.baseUrl ?? ""
        XCTAssertTrue(
            baseUrl.contains("wixapis.com"),
            "Wix adapter base URL must point to wixapis.com, got: \(baseUrl)"
        )

        // Verify all pull URLs also point to wixapis.com
        for resource in config.resources {
            if let pullUrl = resource.pull?.url {
                XCTAssertTrue(
                    pullUrl.contains("wixapis.com"),
                    "Wix \(resource.name) pull URL must point to wixapis.com, got: \(pullUrl)"
                )
            }
        }
    }

    // MARK: - 7. Monday: Verify GraphQL Query Present

    func testMondayAdapterHasGraphQLQuery() throws {
        let config = try loadBundledAdapter(named: "monday.adapter")
        XCTAssertEqual(config.service, "monday")

        for resource in config.resources {
            guard let pull = resource.pull else {
                XCTFail("Monday \(resource.name): pull config must be present")
                continue
            }

            // Monday uses GraphQL for all resources
            XCTAssertEqual(
                pull.type, .graphql,
                "Monday \(resource.name): pull type must be graphql"
            )
            XCTAssertNotNil(
                pull.query,
                "Monday \(resource.name): graphql query must be present"
            )
            XCTAssertFalse(
                pull.query?.isEmpty ?? true,
                "Monday \(resource.name): graphql query must not be empty"
            )
        }
    }

    // MARK: - 8. Airtable: Verify Pagination Config Exists

    func testAirtableAdapterHasPaginationConfig() throws {
        let config = try loadBundledAdapter(named: "airtable.adapter")
        XCTAssertEqual(config.service, "airtable")

        // The records resource should have pagination
        let recordsResource = config.resources.first(where: { $0.name == "records" })
        XCTAssertNotNil(recordsResource, "Airtable must have a 'records' resource")

        let pagination = recordsResource?.pull?.pagination
        XCTAssertNotNil(pagination, "Airtable records must have pagination config")
        XCTAssertEqual(pagination?.type, .offset, "Airtable uses offset-based pagination")
        XCTAssertNotNil(pagination?.pageSize, "Airtable pagination must specify pageSize")

        // Also check the bases resource
        let basesResource = config.resources.first(where: { $0.name == "bases" })
        XCTAssertNotNil(basesResource, "Airtable must have a 'bases' resource")
        XCTAssertNotNil(basesResource?.pull?.pagination, "Airtable bases must have pagination config")
    }

    // MARK: - 9. Demo: Verify 6+ Resources Defined

    func testDemoAdapterHasSixOrMoreResources() throws {
        let config = try loadBundledAdapter(named: "demo.adapter")
        XCTAssertEqual(config.service, "demo")

        XCTAssertGreaterThanOrEqual(
            config.resources.count, 6,
            "Demo adapter must have at least 6 resources, found \(config.resources.count)"
        )

        // Verify expected resource names are present
        let resourceNames = Set(config.resources.map(\.name))
        let expectedNames: Set<String> = ["tasks", "contacts", "events", "notes", "pages", "config"]
        for expected in expectedNames {
            XCTAssertTrue(
                resourceNames.contains(expected),
                "Demo adapter should contain '\(expected)' resource"
            )
        }
    }

    // MARK: - Cross-Cutting: Auth Type Consistency

    func testGitHubUsesBearer() throws {
        let config = try loadBundledAdapter(named: "github.adapter")
        XCTAssertEqual(config.auth.type, .bearer)
    }

    func testWixUsesApiKey() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")
        XCTAssertEqual(config.auth.type, .apiKey)
    }

    func testMondayUsesBearer() throws {
        let config = try loadBundledAdapter(named: "monday.adapter")
        XCTAssertEqual(config.auth.type, .bearer)
    }

    func testAirtableUsesBearer() throws {
        let config = try loadBundledAdapter(named: "airtable.adapter")
        XCTAssertEqual(config.auth.type, .bearer)
    }

    func testDemoUsesBearer() throws {
        let config = try loadBundledAdapter(named: "demo.adapter")
        XCTAssertEqual(config.auth.type, .bearer)
    }
}
