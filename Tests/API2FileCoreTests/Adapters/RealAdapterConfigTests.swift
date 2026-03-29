import XCTest
@testable import API2FileCore

/// Tests that every real (production) adapter config file in the Resources bundle
/// parses correctly and contains the expected structure for its service.
final class RealAdapterConfigTests: XCTestCase {
    private func jsonString(_ value: JSONValue?, path: [String]) -> String? {
        guard let value else { return nil }
        if path.isEmpty {
            if case .string(let string) = value {
                return string
            }
            return nil
        }
        guard case .object(let object) = value else { return nil }
        return jsonString(object[path[0]], path: Array(path.dropFirst()))
    }


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

    func testWixAdapterLocksDownSetupFieldsAndResourceInventory() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        XCTAssertEqual(
            config.setupFields?.map(\.key),
            ["wix-site-id", "wix-site-url"],
            "Wix adapter should require both site id and site url setup fields"
        )

        let expectedResourceNames = [
            "contacts",
            "blog-posts",
            "products",
            "orders",
            "coupons",
            "pricing-plans",
            "gift-cards",
            "forms",
            "members",
            "site-properties",
            "site-urls",
            "media",
            "pro-gallery",
            "pdf-viewer",
            "wix-video",
            "wix-music-podcasts",
            "bookings-services",
            "bookings-appointments",
            "groups",
            "inbox-conversations",
            "comments",
            "events",
            "events-rsvps",
            "events-tickets",
            "restaurant-menus",
            "restaurant-reservations",
            "restaurant-orders",
            "bookings",
            "collections",
            "portfolio-collections",
            "portfolio-projects",
        ]
        XCTAssertEqual(
            config.resources.map(\.name),
            expectedResourceNames,
            "Wix adapter top-level resources changed; update docs/tests intentionally if this is expected"
        )

        let expectedCapabilityClasses: [String: ResourceCapabilityClass] = [
            "contacts": .partialWritable,
            "blog-posts": .fullCRUD,
            "products": .fullCRUD,
            "orders": .partialWritable,
            "coupons": .readOnly,
            "pricing-plans": .readOnly,
            "gift-cards": .readOnly,
            "forms": .partialWritable,
            "members": .fullCRUD,
            "site-properties": .readOnly,
            "site-urls": .readOnly,
            "media": .readOnly,
            "pro-gallery": .readOnly,
            "pdf-viewer": .readOnly,
            "wix-video": .readOnly,
            "wix-music-podcasts": .readOnly,
            "bookings-services": .partialWritable,
            "bookings-appointments": .readOnly,
            "groups": .partialWritable,
            "inbox-conversations": .readOnly,
            "comments": .readOnly,
            "events": .partialWritable,
            "events-rsvps": .readOnly,
            "events-tickets": .readOnly,
            "restaurant-menus": .partialWritable,
            "restaurant-reservations": .readOnly,
            "restaurant-orders": .readOnly,
            "bookings": .partialWritable,
            "collections": .readOnly,
            "portfolio-collections": .fullCRUD,
            "portfolio-projects": .fullCRUD,
        ]
        for resource in config.resources {
            XCTAssertEqual(
                resource.capabilityClass,
                expectedCapabilityClasses[resource.name],
                "Wix \(resource.name) capability class drifted; keep the adapter and live contract matrix aligned"
            )
        }

        let collections = try XCTUnwrap(config.resources.first(where: { $0.name == "collections" }))
        XCTAssertEqual(collections.capabilityClass, .readOnly)
        XCTAssertEqual(collections.fileMapping.format, .json)
        XCTAssertEqual(collections.children?.count, 1)
        XCTAssertTrue(
            collections.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "match" && $0.field == "displayNamespace" && $0.value == ""
            }) == true,
            "Wix collections should exclude app-owned namespaces before pulling child items"
        )
        XCTAssertTrue(
            collections.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "match" && $0.field == "collectionType" && $0.value == "NATIVE"
            }) == true,
            "Wix collections should only expose NATIVE collections in the generic writable CMS surface"
        )
        XCTAssertTrue(
            collections.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "containsAll" &&
                $0.field == "capabilities.dataOperations" &&
                Set($0.fields ?? []).isSuperset(of: ["INSERT", "UPDATE", "REMOVE"])
            }) == true,
            "Wix collections should only expose metadata-proven writable collections in the generic CMS surface"
        )
        XCTAssertFalse(
            collections.fileMapping.transforms?.pull?.contains(where: { $0.op == "excludeRegex" }) == true,
            "The bundled Wix adapter should stay site-agnostic and avoid name-based collection exclusions"
        )

        let items = try XCTUnwrap(collections.children?.first)
        XCTAssertEqual(items.name, "items")
        XCTAssertEqual(items.capabilityClass, .fullCRUD)
        XCTAssertEqual(items.fileMapping.format, .csv)
        XCTAssertEqual(items.fileMapping.directory, "cms")
        XCTAssertEqual(items.fileMapping.filename, "{displayName|slugify}.csv")
        XCTAssertEqual(items.fileMapping.effectivePushMode, .custom)
        XCTAssertTrue(
            items.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "spread" && $0.path == "data"
            }) == true,
            "Wix CMS item files should flatten nested data into friendly CSV columns"
        )
        XCTAssertTrue(
            items.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("dataCollectionId") == true) &&
                ($0.fields?.contains("_url") == true)
            }) == true,
            "Wix CMS item files should omit sync metadata from the human CSV projection"
        )
        XCTAssertEqual(items.push?.delete?.url, "https://www.wixapis.com/wix-data/v2/items/{id}?dataCollectionId={dataCollectionId}")
        XCTAssertEqual(items.push?.create?.bodyType, "wix-cms-item-create")
        XCTAssertEqual(items.push?.update?.bodyType, "wix-cms-item-update")
        XCTAssertNil(items.push?.create?.bodyWrapper)
        XCTAssertNil(items.push?.update?.bodyWrapper)

        let portfolioProjects = try XCTUnwrap(config.resources.first(where: { $0.name == "portfolio-projects" }))
        XCTAssertEqual(portfolioProjects.capabilityClass, .fullCRUD)
        XCTAssertEqual(portfolioProjects.fileMapping.format, .csv)
        XCTAssertEqual(portfolioProjects.children?.count, 1)

        let projectItems = try XCTUnwrap(portfolioProjects.children?.first)
        XCTAssertEqual(projectItems.name, "portfolio-project-items")
        XCTAssertEqual(projectItems.capabilityClass, .fullCRUD)
        XCTAssertEqual(projectItems.fileMapping.format, .json)
        XCTAssertEqual(projectItems.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(projectItems.pull?.url, "https://www.wixapis.com/portfolio/v1/projects/{id}/items/query")
        XCTAssertEqual(projectItems.push?.create?.url, "https://www.wixapis.com/portfolio/v1/projects/{id}/items")
        XCTAssertEqual(projectItems.push?.update?.url, "https://www.wixapis.com/portfolio/v1/projects/{id}/items/{itemId}")
        XCTAssertEqual(projectItems.push?.delete?.url, "https://www.wixapis.com/portfolio/v1/projects/{id}/items/{itemId}")
        XCTAssertEqual(projectItems.push?.create?.bodyWrapper, "item")
        XCTAssertEqual(projectItems.push?.update?.bodyWrapper, "item")
    }

    func testWixAdapterAddsHumanFriendlyOrdersFormsMembersAndSiteProperties() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        let orders = try XCTUnwrap(config.resources.first(where: { $0.name == "orders" }))
        XCTAssertEqual(orders.capabilityClass, .partialWritable)
        XCTAssertEqual(orders.fileMapping.filename, "orders.csv")
        XCTAssertEqual(orders.fileMapping.format, .csv)
        XCTAssertEqual(orders.fileMapping.effectivePushMode, .custom)
        XCTAssertEqual(orders.pull?.url, "https://www.wixapis.com/ecom/v1/orders/search")
        XCTAssertEqual(orders.push?.update?.url, "https://www.wixapis.com/ecom/v1/orders/{id}")
        XCTAssertNil(orders.push?.create, "Orders should not expose create in the first pass")
        XCTAssertTrue(
            orders.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "number" && $0.to == "orderNumber"
            }) == true,
            "Orders should surface a readable orderNumber column in the human CSV"
        )

        let forms = try XCTUnwrap(config.resources.first(where: { $0.name == "forms" }))
        XCTAssertEqual(forms.capabilityClass, .partialWritable)
        XCTAssertEqual(forms.fileMapping.filename, "forms.csv")
        XCTAssertEqual(forms.fileMapping.format, .csv)
        XCTAssertEqual(forms.fileMapping.effectivePushMode, .custom)
        XCTAssertEqual(forms.pull?.url, "https://www.wixapis.com/form-schema-service/v4/forms/query")
        XCTAssertEqual(forms.push?.create?.url, "https://www.wixapis.com/form-schema-service/v4/forms")
        XCTAssertEqual(forms.push?.update?.url, "https://www.wixapis.com/form-schema-service/v4/forms/{id}")
        XCTAssertEqual(forms.push?.delete?.url, "https://www.wixapis.com/form-schema-service/v4/forms/{id}")
        XCTAssertEqual(
            jsonString(forms.pull?.body, path: ["query", "filter", "namespace", "$eq"]),
            "wix.form_platform.form",
            "Forms should target the live Wix form platform namespace"
        )
        XCTAssertTrue(
            forms.fileMapping.transforms?.push?.contains(where: {
                $0.op == "set" && $0.field == "namespace" && $0.value == "wix.form_platform.form"
            }) == true,
            "Forms push should inject the live Wix form namespace"
        )
        XCTAssertFalse(
            forms.fileMapping.transforms?.push?.contains(where: {
                $0.op == "omit" && ($0.fields ?? []).contains("namespace")
            }) == true,
            "Forms push must not omit namespace after injecting it for create/update requests"
        )
        XCTAssertEqual(forms.children?.count, 1)

        let submissions = try XCTUnwrap(forms.children?.first)
        XCTAssertEqual(submissions.name, "submissions")
        XCTAssertEqual(submissions.capabilityClass, .partialWritable)
        XCTAssertEqual(submissions.fileMapping.directory, "forms")
        XCTAssertEqual(submissions.fileMapping.filename, "{name|slugify}-submissions.csv")
        XCTAssertEqual(submissions.fileMapping.format, .csv)
        XCTAssertEqual(submissions.fileMapping.effectivePushMode, .custom)
        XCTAssertEqual(submissions.pull?.url, "https://www.wixapis.com/form-submission-service/v4/submissions/namespace/query")
        XCTAssertEqual(submissions.push?.create?.url, "https://www.wixapis.com/form-submission-service/v4/submissions")
        XCTAssertEqual(submissions.push?.update?.url, "https://www.wixapis.com/form-submission-service/v4/submissions/{id}")
        XCTAssertEqual(
            jsonString(submissions.pull?.body, path: ["query", "filter", "namespace", "$eq"]),
            "wix.form_platform.form",
            "Form submissions should query the same live namespace as forms"
        )
        XCTAssertNil(submissions.push?.delete, "Form submissions should not map row deletion to API delete in the first pass")
        XCTAssertTrue(
            submissions.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "submitter.memberId" && $0.to == "submitterMemberId"
            }) == true,
            "Form submissions should flatten submitter IDs into readable CSV columns"
        )

        let members = try XCTUnwrap(config.resources.first(where: { $0.name == "members" }))
        XCTAssertEqual(members.capabilityClass, .fullCRUD)
        XCTAssertEqual(members.fileMapping.filename, "members.csv")
        XCTAssertEqual(members.fileMapping.format, .csv)
        XCTAssertEqual(members.fileMapping.effectivePushMode, .custom)
        XCTAssertEqual(members.pull?.url, "https://www.wixapis.com/members/v1/members/query")
        XCTAssertEqual(members.push?.create?.url, "https://www.wixapis.com/members/v1/members")
        XCTAssertEqual(members.push?.update?.url, "https://www.wixapis.com/members/v1/members/{id}")
        XCTAssertEqual(members.push?.delete?.url, "https://www.wixapis.com/members/v1/members/{id}")
        XCTAssertTrue(
            members.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "profile.nickname" && $0.to == "nickname"
            }) == true,
            "Members should flatten profile.nickname into a readable CSV column"
        )

        let siteProperties = try XCTUnwrap(config.resources.first(where: { $0.name == "site-properties" }))
        XCTAssertEqual(siteProperties.capabilityClass, .readOnly)
        XCTAssertEqual(siteProperties.fileMapping.filename, "site-properties.json")
        XCTAssertEqual(siteProperties.fileMapping.format, .json)
        XCTAssertEqual(siteProperties.fileMapping.readOnly, true)
        XCTAssertEqual(siteProperties.pull?.url, "https://www.wixapis.com/site-properties/v4/properties")
        XCTAssertNil(siteProperties.push, "Site properties should stay read-only in the first pass")

        let siteURLs = try XCTUnwrap(config.resources.first(where: { $0.name == "site-urls" }))
        XCTAssertEqual(siteURLs.capabilityClass, .readOnly)
        XCTAssertEqual(siteURLs.fileMapping.directory, "site")
        XCTAssertEqual(siteURLs.fileMapping.filename, "site-urls.json")
        XCTAssertEqual(siteURLs.fileMapping.format, .json)
        XCTAssertEqual(siteURLs.fileMapping.readOnly, true)
        XCTAssertEqual(siteURLs.pull?.url, "https://www.wixapis.com/urls-server/v2/published-site-urls")
        XCTAssertNil(siteURLs.push, "Site URLs should stay read-only")
    }

    func testWixAdapterAddsBusinessCatalogResources() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        let coupons = try XCTUnwrap(config.resources.first(where: { $0.name == "coupons" }))
        XCTAssertEqual(coupons.capabilityClass, .readOnly)
        XCTAssertEqual(coupons.fileMapping.filename, "coupons.csv")
        XCTAssertEqual(coupons.fileMapping.format, .csv)
        XCTAssertEqual(coupons.fileMapping.readOnly, true)
        XCTAssertEqual(coupons.pull?.url, "https://www.wixapis.com/stores/v2/coupons/query")

        let pricingPlans = try XCTUnwrap(config.resources.first(where: { $0.name == "pricing-plans" }))
        XCTAssertEqual(pricingPlans.capabilityClass, .readOnly)
        XCTAssertEqual(pricingPlans.fileMapping.filename, "pricing-plans.csv")
        XCTAssertEqual(pricingPlans.fileMapping.format, .csv)
        XCTAssertEqual(pricingPlans.fileMapping.readOnly, true)
        XCTAssertEqual(pricingPlans.pull?.url, "https://www.wixapis.com/pricing-plans/v3/plans/query")

        let giftCards = try XCTUnwrap(config.resources.first(where: { $0.name == "gift-cards" }))
        XCTAssertEqual(giftCards.capabilityClass, .readOnly)
        XCTAssertEqual(giftCards.fileMapping.filename, "gift-cards.csv")
        XCTAssertEqual(giftCards.fileMapping.format, .csv)
        XCTAssertEqual(giftCards.fileMapping.readOnly, true)
        XCTAssertEqual(giftCards.pull?.url, "https://www.wixapis.com/gift-cards/v1/gift-cards/query")

        let events = try XCTUnwrap(config.resources.first(where: { $0.name == "events" }))
        XCTAssertEqual(events.capabilityClass, .partialWritable)
        XCTAssertEqual(events.fileMapping.filename, "events.csv")
        XCTAssertEqual(events.fileMapping.format, .csv)
        XCTAssertEqual(events.pull?.url, "https://www.wixapis.com/events/v3/events/query")
        XCTAssertEqual(events.push?.update?.url, "https://www.wixapis.com/events/v1/events/{id}")

        let eventRSVPs = try XCTUnwrap(config.resources.first(where: { $0.name == "events-rsvps" }))
        XCTAssertEqual(eventRSVPs.capabilityClass, .readOnly)
        XCTAssertEqual(eventRSVPs.fileMapping.directory, "events")
        XCTAssertEqual(eventRSVPs.fileMapping.filename, "rsvps.csv")
        XCTAssertEqual(eventRSVPs.fileMapping.readOnly, true)
        XCTAssertEqual(eventRSVPs.pull?.url, "https://www.wixapis.com/events/v2/rsvps/query")

        let eventTickets = try XCTUnwrap(config.resources.first(where: { $0.name == "events-tickets" }))
        XCTAssertEqual(eventTickets.capabilityClass, .readOnly)
        XCTAssertEqual(eventTickets.fileMapping.directory, "events")
        XCTAssertEqual(eventTickets.fileMapping.filename, "tickets.csv")
        XCTAssertEqual(eventTickets.fileMapping.readOnly, true)
        XCTAssertEqual(eventTickets.pull?.url, "https://www.wixapis.com/events-ticket-definitions/v3/ticket-definitions/query")

        let restaurantMenus = try XCTUnwrap(config.resources.first(where: { $0.name == "restaurant-menus" }))
        XCTAssertEqual(restaurantMenus.capabilityClass, .partialWritable)
        XCTAssertEqual(restaurantMenus.fileMapping.directory, "restaurant")
        XCTAssertEqual(restaurantMenus.fileMapping.filename, "menus.csv")
        XCTAssertEqual(restaurantMenus.pull?.url, "https://www.wixapis.com/restaurants/menus-menu/v1/menus/query")
        XCTAssertEqual(restaurantMenus.push?.create?.url, "https://www.wixapis.com/restaurants/menus-menu/v1/menus")
        XCTAssertEqual(restaurantMenus.push?.delete?.url, "https://www.wixapis.com/restaurants/menus-menu/v1/menus/{id}")

        let restaurantReservations = try XCTUnwrap(config.resources.first(where: { $0.name == "restaurant-reservations" }))
        XCTAssertEqual(restaurantReservations.capabilityClass, .readOnly)
        XCTAssertEqual(restaurantReservations.fileMapping.directory, "restaurant")
        XCTAssertEqual(restaurantReservations.fileMapping.filename, "reservations.csv")
        XCTAssertEqual(restaurantReservations.fileMapping.readOnly, true)
        XCTAssertEqual(restaurantReservations.pull?.url, "https://www.wixapis.com/table-reservations/reservations/v1/reservations/query")

        let restaurantOrders = try XCTUnwrap(config.resources.first(where: { $0.name == "restaurant-orders" }))
        XCTAssertEqual(restaurantOrders.capabilityClass, .readOnly)
        XCTAssertEqual(restaurantOrders.fileMapping.directory, "restaurant")
        XCTAssertEqual(restaurantOrders.fileMapping.filename, "orders.csv")
        XCTAssertEqual(restaurantOrders.fileMapping.readOnly, true)
        XCTAssertEqual(restaurantOrders.pull?.url, "https://www.wixapis.com/restaurants/v3/orders")
    }

    func testWixAdapterLocksDownMediaAndReadOnlyBehavior() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        for name in ["media", "pro-gallery", "pdf-viewer", "wix-video", "wix-music-podcasts"] {
            let resource = try XCTUnwrap(config.resources.first(where: { $0.name == name }))
            XCTAssertEqual(resource.pull?.type, .media, "\(name) should use media pull mode")
            XCTAssertNotNil(resource.pull?.mediaConfig, "\(name) should declare mediaConfig")
            XCTAssertEqual(resource.fileMapping.strategy, .mirror, "\(name) should mirror binary files")
            XCTAssertEqual(resource.fileMapping.format, .raw, "\(name) should use raw binary format")
        }

        let appointments = try XCTUnwrap(config.resources.first(where: { $0.name == "bookings-appointments" }))
        XCTAssertEqual(appointments.fileMapping.filename, "appointments.csv")
        XCTAssertEqual(appointments.fileMapping.format, .csv)
        XCTAssertEqual(appointments.fileMapping.readOnly, true)

        let comments = try XCTUnwrap(config.resources.first(where: { $0.name == "comments" }))
        XCTAssertEqual(comments.capabilityClass, .readOnly)
        XCTAssertEqual(comments.fileMapping.filename, "comments.csv")
        XCTAssertEqual(comments.fileMapping.readOnly, true)

        let siteProperties = try XCTUnwrap(config.resources.first(where: { $0.name == "site-properties" }))
        XCTAssertEqual(siteProperties.fileMapping.readOnly, true)

        let products = try XCTUnwrap(config.resources.first(where: { $0.name == "products" }))
        XCTAssertEqual(products.capabilityClass, .fullCRUD)
        XCTAssertEqual(products.push?.create?.bodyType, "wix-product-create")
        XCTAssertEqual(products.push?.update?.bodyType, "wix-product-update")
        XCTAssertNil(
            products.pull?.updatedSinceBodyPath,
            "Wix products incremental updatedDate filtering is too lossy for reliable server-to-file propagation"
        )
    }

    func testWixHumanFacingFormatsStaySanitized() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        let contacts = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))
        XCTAssertTrue(
            contacts.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("revision") == true) &&
                ($0.fields?.contains("source") == true) &&
                ($0.fields?.contains("createdDate") == true) &&
                ($0.fields?.contains("memberInfo") == true)
            }) == true,
            "Contacts CSV should hide sync-heavy fields from the human file"
        )
        XCTAssertTrue(
            contacts.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "info.emails.items.0.email" && $0.to == "primaryEmail"
            }) == true,
            "Contacts CSV should flatten the primary email into a simple human field"
        )

        let blogPosts = try XCTUnwrap(config.resources.first(where: { $0.name == "blog-posts" }))
        XCTAssertEqual(blogPosts.fileMapping.format, .markdown)
        XCTAssertEqual(blogPosts.fileMapping.contentField, "contentText")
        XCTAssertEqual(blogPosts.fileMapping.formatOptions?.fieldMapping?["richContent"], "richContent")

        let bookings = try XCTUnwrap(config.resources.first(where: { $0.name == "bookings" }))
        XCTAssertEqual(bookings.capabilityClass, .partialWritable)
        XCTAssertEqual(bookings.fileMapping.format, .json)

        let groups = try XCTUnwrap(config.resources.first(where: { $0.name == "groups" }))
        XCTAssertTrue(
            groups.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("ownerId") == true) &&
                ($0.fields?.contains("membersCount") == true)
            }) == true,
            "Groups CSV should hide owner/member-count bookkeeping from the human file"
        )
        XCTAssertTrue(
            groups.fileMapping.transforms?.push?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("createdDate") == true) &&
                ($0.fields?.contains("updatedDate") == true)
            }) == true,
            "Groups CSV should drop server-managed fields from the human push payload"
        )

        let products = try XCTUnwrap(config.resources.first(where: { $0.name == "products" }))
        XCTAssertTrue(
            products.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("revision") == true) &&
                ($0.fields?.contains("createdDate") == true) &&
                ($0.fields?.contains("updatedDate") == true)
            }) == true,
            "Products CSV should keep revision/timestamp metadata out of the human file"
        )

        let members = try XCTUnwrap(config.resources.first(where: { $0.name == "members" }))
        XCTAssertTrue(
            members.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("contactId") == true) &&
                ($0.fields?.contains("status") == true)
            }) == true,
            "Members CSV should hide contact linkage and server state bookkeeping"
        )

        let events = try XCTUnwrap(config.resources.first(where: { $0.name == "events" }))
        XCTAssertTrue(
            events.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("createdDate") == true) &&
                ($0.fields?.contains("instanceId") == true) &&
                ($0.fields?.contains("eventPageUrl") == true)
            }) == true,
            "Events CSV should hide dashboard and publication metadata"
        )

        let bookingsServices = try XCTUnwrap(config.resources.first(where: { $0.name == "bookings-services" }))
        XCTAssertTrue(
            bookingsServices.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("revision") == true) &&
                ($0.fields?.contains("serviceResources") == true) &&
                ($0.fields?.contains("urls") == true)
            }) == true,
            "Bookings services CSV should hide internal service scaffolding"
        )

        let collections = try XCTUnwrap(config.resources.first(where: { $0.name == "collections" }))
        XCTAssertTrue(
            collections.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "omit" &&
                ($0.fields?.contains("revision") == true) &&
                ($0.fields?.contains("fields") == true) &&
                ($0.fields?.contains("plugins") == true)
            }) == true,
            "Collections catalog should hide bulky implementation metadata from the human JSON"
        )
    }

    func testWixHumanFacingFormatsDoNotProjectUnderscoreURLs() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")

        for resource in config.resources {
            XCTAssertFalse(
                resource.fileMapping.transforms?.pull?.contains(where: {
                    $0.op == "set" && $0.field == "_url"
                }) == true,
                "Wix \(resource.name) should not expose _url in the human projection"
            )

            for child in resource.children ?? [] {
                XCTAssertFalse(
                    child.fileMapping.transforms?.pull?.contains(where: {
                        $0.op == "set" && $0.field == "_url"
                    }) == true,
                    "Wix \(resource.name).\(child.name) should not expose _url in the human projection"
                )
            }
        }
    }

    func testWixBlogPostsDoNotUseUnsupportedIncrementalFilter() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")
        let blogPosts = try XCTUnwrap(config.resources.first(where: { $0.name == "blog-posts" }))

        XCTAssertNil(
            blogPosts.pull?.updatedSinceBodyPath,
            "Wix blog posts query does not support updatedDate filtering; keep incremental body filters disabled"
        )
        XCTAssertEqual(blogPosts.pull?.detail?.url, "https://www.wixapis.com/blog/v3/posts/{id}?fieldsets=RICH_CONTENT")
        XCTAssertEqual(blogPosts.pull?.detail?.dataPath, "$.post")
        XCTAssertEqual(blogPosts.fileMapping.contentField, "contentText")
        XCTAssertEqual(blogPosts.fileMapping.formatOptions?.fieldMapping?["richContent"], "richContent")
        XCTAssertTrue(
            blogPosts.fileMapping.transforms?.push?.contains(where: {
                $0.op == "pick" && ($0.fields ?? []).contains("richContent")
            }) == true,
            "Wix blog posts should explicitly pick richContent for Markdown push payloads"
        )
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

    func testMondayAdapterUsesCustomGraphQLBodiesForItemMutations() throws {
        let config = try loadBundledAdapter(named: "monday.adapter")
        let boards = try XCTUnwrap(config.resources.first(where: { $0.name == "boards" }))
        let items = try XCTUnwrap(boards.children?.first(where: { $0.name == "items" }))

        XCTAssertEqual(items.push?.create?.type, .graphql)
        XCTAssertEqual(items.push?.create?.bodyType, "monday-item-create")
        XCTAssertNil(
            items.push?.create?.mutation,
            "Monday item create should build a GraphQL variables body instead of using an inline mutation template"
        )

        XCTAssertEqual(items.push?.update?.type, .graphql)
        XCTAssertEqual(items.push?.update?.bodyType, "monday-item-update")
        XCTAssertNil(
            items.push?.update?.mutation,
            "Monday item update should build a GraphQL variables body instead of using an inline mutation template"
        )

        XCTAssertEqual(
            items.push?.delete?.mutation,
            "mutation { delete_item(item_id: {id}) { id } }"
        )
    }

    func testMondayBoardsSurfaceReadOnlySnapshotsAndWritableItemsFiles() throws {
        let config = try loadBundledAdapter(named: "monday.adapter")
        let boards = try XCTUnwrap(config.resources.first(where: { $0.name == "boards" }))
        let items = try XCTUnwrap(boards.children?.first(where: { $0.name == "items" }))

        XCTAssertEqual(boards.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(boards.fileMapping.directory, "boards")
        XCTAssertEqual(boards.fileMapping.filename, "{name|slugify}.csv")
        XCTAssertEqual(boards.fileMapping.format, .csv)
        XCTAssertEqual(boards.fileMapping.readOnly, true)

        XCTAssertEqual(items.fileMapping.strategy, .collection)
        XCTAssertEqual(items.fileMapping.directory, "boards/{name|slugify}")
        XCTAssertEqual(items.fileMapping.filename, "items.csv")
        XCTAssertEqual(items.fileMapping.format, .csv)
        XCTAssertEqual(items.pull?.dataPath, "$.data.boards[0].items_page.items")
        XCTAssertTrue(
            items.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "board.id" && $0.to == "boardId"
            }) == true
        )
    }

    func testWixContactsUseCustomBodiesAndReadableNameProjection() throws {
        let config = try loadBundledAdapter(named: "wix.adapter")
        let contacts = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))

        XCTAssertEqual(contacts.push?.create?.bodyType, "wix-contact-create")
        XCTAssertEqual(contacts.push?.update?.bodyType, "wix-contact-update")
        XCTAssertNil(contacts.push?.create?.bodyWrapper)
        XCTAssertNil(contacts.push?.update?.bodyWrapper)

        XCTAssertTrue(
            contacts.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "spread" && $0.path == "info.name"
            }) == true,
            "Wix contacts should spread info.name so first/last are visible in the human CSV"
        )
        XCTAssertTrue(
            contacts.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "spread" && $0.path == "primaryEmail"
            }) == true,
            "Wix contacts should spread primaryEmail so the human CSV projects a plain email value"
        )
        XCTAssertTrue(
            contacts.fileMapping.transforms?.pull?.contains(where: {
                $0.op == "rename" && $0.from == "email" && $0.to == "primaryEmail"
            }) == true,
            "Wix contacts should rename the spread email field back to primaryEmail for a readable human column"
        )
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
