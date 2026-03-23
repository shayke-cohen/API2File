import XCTest
@testable import API2FileCore

final class DemoAdapterConfigTests: XCTestCase {

    // MARK: - Helpers

    private func loadBundledAdapter(named name: String) throws -> AdapterConfig {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Adapters") else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Adapter \(name) not found in bundle"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AdapterConfig.self, from: data)
    }

    // MARK: - TeamBoard

    func testTeamBoardAdapterParses() throws {
        let config = try loadBundledAdapter(named: "teamboard.adapter")
        XCTAssertEqual(config.service, "teamboard")
        XCTAssertEqual(config.displayName, "TeamBoard — Project Management")
        XCTAssertEqual(config.auth.type, .bearer)
        XCTAssertEqual(config.resources.count, 2)

        // Tasks resource
        let tasks = config.resources[0]
        XCTAssertEqual(tasks.name, "tasks")
        XCTAssertEqual(tasks.fileMapping.strategy, .collection)
        XCTAssertEqual(tasks.fileMapping.format, .csv)
        XCTAssertEqual(tasks.fileMapping.filename, "tasks.csv")
        XCTAssertEqual(tasks.sync?.interval, 15)

        // Config resource
        let configRes = config.resources[1]
        XCTAssertEqual(configRes.name, "config")
        XCTAssertEqual(configRes.fileMapping.strategy, .collection)
        XCTAssertEqual(configRes.fileMapping.format, .yaml)
        XCTAssertEqual(configRes.fileMapping.filename, "settings.yaml")
    }

    // MARK: - PeopleHub

    func testPeopleHubAdapterParses() throws {
        let config = try loadBundledAdapter(named: "peoplehub.adapter")
        XCTAssertEqual(config.service, "peoplehub")
        XCTAssertEqual(config.resources.count, 2)

        // Contacts resource
        let contacts = config.resources[0]
        XCTAssertEqual(contacts.name, "contacts")
        XCTAssertEqual(contacts.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(contacts.fileMapping.format, .vcf)
        XCTAssertEqual(contacts.fileMapping.directory, "contacts")
        XCTAssertEqual(contacts.fileMapping.filename, "{firstName|slugify}-{lastName|slugify}.vcf")
        XCTAssertEqual(contacts.sync?.interval, 20)

        // Notes resource
        let notes = config.resources[1]
        XCTAssertEqual(notes.name, "notes")
        XCTAssertEqual(notes.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(notes.fileMapping.format, .markdown)
        XCTAssertEqual(notes.fileMapping.contentField, "content")
    }

    // MARK: - CalSync

    func testCalSyncAdapterParses() throws {
        let config = try loadBundledAdapter(named: "calsync.adapter")
        XCTAssertEqual(config.service, "calsync")
        XCTAssertEqual(config.resources.count, 2)

        // Events resource
        let events = config.resources[0]
        XCTAssertEqual(events.name, "events")
        XCTAssertEqual(events.fileMapping.strategy, .collection)
        XCTAssertEqual(events.fileMapping.format, .ics)
        XCTAssertEqual(events.fileMapping.filename, "calendar.ics")

        // Action items resource
        let items = config.resources[1]
        XCTAssertEqual(items.name, "action-items")
        XCTAssertEqual(items.fileMapping.strategy, .collection)
        XCTAssertEqual(items.fileMapping.format, .csv)
        XCTAssertEqual(items.fileMapping.filename, "action-items.csv")
    }

    // MARK: - PageCraft

    func testPageCraftAdapterParses() throws {
        let config = try loadBundledAdapter(named: "pagecraft.adapter")
        XCTAssertEqual(config.service, "pagecraft")
        XCTAssertEqual(config.resources.count, 3)

        // Pages resource
        let pages = config.resources[0]
        XCTAssertEqual(pages.name, "pages")
        XCTAssertEqual(pages.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(pages.fileMapping.format, .html)
        XCTAssertEqual(pages.fileMapping.filename, "{slug}.html")
        XCTAssertEqual(pages.fileMapping.contentField, "content")

        // Blog posts resource
        let blog = config.resources[1]
        XCTAssertEqual(blog.name, "blog-posts")
        XCTAssertEqual(blog.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(blog.fileMapping.format, .markdown)
        XCTAssertEqual(blog.fileMapping.directory, "blog")

        // Config resource
        let configRes = config.resources[2]
        XCTAssertEqual(configRes.name, "config")
        XCTAssertEqual(configRes.fileMapping.strategy, .collection)
        XCTAssertEqual(configRes.fileMapping.format, .json)
        XCTAssertEqual(configRes.fileMapping.filename, "site.json")
    }

    // MARK: - DevOps

    func testDevOpsAdapterParses() throws {
        let config = try loadBundledAdapter(named: "devops.adapter")
        XCTAssertEqual(config.service, "devops")
        XCTAssertEqual(config.resources.count, 2)

        // Services resource
        let services = config.resources[0]
        XCTAssertEqual(services.name, "services")
        XCTAssertEqual(services.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(services.fileMapping.format, .json)
        XCTAssertEqual(services.fileMapping.filename, "{name|slugify}.json")
        XCTAssertEqual(services.fileMapping.directory, "services")

        // Incidents resource
        let incidents = config.resources[1]
        XCTAssertEqual(incidents.name, "incidents")
        XCTAssertEqual(incidents.fileMapping.strategy, .collection)
        XCTAssertEqual(incidents.fileMapping.format, .csv)
        XCTAssertEqual(incidents.fileMapping.filename, "incidents.csv")
    }

    // MARK: - MediaManager

    func testMediaManagerAdapterParses() throws {
        let config = try loadBundledAdapter(named: "mediamanager.adapter")
        XCTAssertEqual(config.service, "mediamanager")
        XCTAssertEqual(config.resources.count, 3)

        // Logos resource (SVG)
        let logos = config.resources[0]
        XCTAssertEqual(logos.name, "logos")
        XCTAssertEqual(logos.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(logos.fileMapping.format, .svg)
        XCTAssertEqual(logos.fileMapping.filename, "{name|slugify}.svg")
        XCTAssertEqual(logos.fileMapping.directory, "logos")

        // Photos resource (PNG via raw/base64)
        let photos = config.resources[1]
        XCTAssertEqual(photos.name, "photos")
        XCTAssertEqual(photos.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(photos.fileMapping.format, .raw)
        XCTAssertEqual(photos.fileMapping.filename, "{name|slugify}.png")

        // Documents resource (PDF via raw/base64)
        let docs = config.resources[2]
        XCTAssertEqual(docs.name, "documents")
        XCTAssertEqual(docs.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(docs.fileMapping.format, .raw)
        XCTAssertEqual(docs.fileMapping.filename, "{name|slugify}.pdf")
    }

    // MARK: - Wix Demo

    func testWixDemoAdapterParses() throws {
        let config = try loadBundledAdapter(named: "wix-demo.adapter")
        XCTAssertEqual(config.service, "wix-demo")
        XCTAssertEqual(config.displayName, "Wix Demo — Local Mock Server")
        XCTAssertEqual(config.auth.type, .bearer)
        XCTAssertEqual(config.auth.keychainKey, "api2file.wix-demo.key")
        XCTAssertEqual(config.globals?.baseUrl, "http://localhost:8089")
        XCTAssertEqual(config.resources.count, 5)

        // Contacts resource
        let contacts = config.resources[0]
        XCTAssertEqual(contacts.name, "contacts")
        XCTAssertEqual(contacts.pull?.dataPath, "$.contacts")
        XCTAssertEqual(contacts.fileMapping.strategy, .collection)
        XCTAssertEqual(contacts.fileMapping.format, .csv)
        XCTAssertEqual(contacts.fileMapping.filename, "contacts.csv")
        XCTAssertNotNil(contacts.fileMapping.transforms?.pull)
        XCTAssertEqual(contacts.fileMapping.transforms?.pull?.count, 4)

        // Blog posts resource
        let blogPosts = config.resources[1]
        XCTAssertEqual(blogPosts.name, "blog-posts")
        XCTAssertEqual(blogPosts.pull?.dataPath, "$.posts")
        XCTAssertEqual(blogPosts.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(blogPosts.fileMapping.format, .markdown)
        XCTAssertEqual(blogPosts.fileMapping.directory, "blog")
        XCTAssertEqual(blogPosts.fileMapping.contentField, "richContent")

        // Products resource
        let products = config.resources[2]
        XCTAssertEqual(products.name, "products")
        XCTAssertEqual(products.pull?.dataPath, "$.products")
        XCTAssertEqual(products.fileMapping.strategy, .collection)
        XCTAssertEqual(products.fileMapping.format, .csv)
        XCTAssertEqual(products.fileMapping.filename, "products.csv")
        XCTAssertNotNil(products.fileMapping.transforms?.pull)

        // Bookings resource
        let bookings = config.resources[3]
        XCTAssertEqual(bookings.name, "bookings")
        XCTAssertEqual(bookings.pull?.dataPath, "$.services")
        XCTAssertEqual(bookings.fileMapping.strategy, .onePerRecord)
        XCTAssertEqual(bookings.fileMapping.format, .json)
        XCTAssertEqual(bookings.fileMapping.readOnly, true)

        // Collections resource
        let collections = config.resources[4]
        XCTAssertEqual(collections.name, "collections")
        XCTAssertEqual(collections.pull?.dataPath, "$.collections")
        XCTAssertEqual(collections.fileMapping.strategy, .collection)
        XCTAssertEqual(collections.fileMapping.format, .json)
        XCTAssertEqual(collections.fileMapping.readOnly, true)
    }

    // MARK: - All adapters share same base URL

    func testAllAdaptersPointToLocalDemoServer() throws {
        let adapterNames = ["teamboard.adapter", "peoplehub.adapter", "calsync.adapter", "pagecraft.adapter", "devops.adapter", "mediamanager.adapter", "wix-demo.adapter"]
        for name in adapterNames {
            let config = try loadBundledAdapter(named: name)
            XCTAssertEqual(config.globals?.baseUrl, "http://localhost:8089", "\(config.service) should point to localhost:8089")
            XCTAssertEqual(config.auth.type, .bearer, "\(config.service) should use bearer auth")
        }
    }
}
