import XCTest
@testable import API2FileiOSApp
import API2FileCore

@MainActor
final class IOSWixServiceBootstrapTests: XCTestCase {
    func testBootstrapWixServiceFromEnvironment() async throws {
        let env = ProcessInfo.processInfo.environment
        guard
            let apiKey = env["WIX_API_KEY"], !apiKey.isEmpty,
            let siteID = env["WIX_SITE_ID"], !siteID.isEmpty,
            let siteURL = env["WIX_SITE_URL"], !siteURL.isEmpty
        else {
            throw XCTSkip("Requires WIX_API_KEY, WIX_SITE_ID, and WIX_SITE_URL")
        }

        let appState = IOSAppState()
        await appState.startEngineIfNeeded()

        if appState.services.contains(where: { $0.serviceId == "wix" }) {
            await appState.removeService("wix")
        }

        let templates = try await appState.platformServices.adapterStore.loadAll()
        guard let wixTemplate = templates.first(where: { $0.config.service == "wix" }) else {
            XCTFail("Expected bundled Wix template")
            return
        }

        try await appState.addService(
            template: wixTemplate,
            apiKey: apiKey,
            extraFieldValues: [
                "wix-site-id": siteID,
                "wix-site-url": siteURL,
            ]
        )

        let serviceDir = appState.syncRootURL.appendingPathComponent("wix", isDirectory: true)
        let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
        let adapterData = try Data(contentsOf: adapterURL)
        let adapterText = try XCTUnwrap(String(data: adapterData, encoding: .utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: adapterURL.path))
        XCTAssertFalse(adapterText.contains("YOUR_SITE_ID_HERE"))
        XCTAssertFalse(adapterText.contains("YOUR_SITE_URL_HERE"))
        XCTAssertTrue(adapterText.contains(siteID))
        XCTAssertTrue(adapterText.contains(siteURL))

        let storedKey = await appState.platformServices.keychainManager.load(key: "api2file.wix.key")
        XCTAssertEqual(storedKey, apiKey)

        await appState.refresh()
        XCTAssertTrue(appState.services.contains(where: { $0.serviceId == "wix" }))
        XCTAssertEqual(appState.selectedServiceID, "wix")
    }
}
