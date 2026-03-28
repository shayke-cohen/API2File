import XCTest
@testable import API2FileiOSApp
import API2FileCore

@MainActor
final class IOSMondayServiceBootstrapTests: XCTestCase {
    func testBootstrapMondayServiceFromEnvironment() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["MONDAY_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("Requires MONDAY_API_KEY")
        }

        let appState = IOSAppState()
        await appState.startEngineIfNeeded()

        if appState.services.contains(where: { $0.serviceId == "monday" }) {
            await appState.removeService("monday")
        }

        let templates = try await appState.platformServices.adapterStore.loadAll()
        guard let mondayTemplate = templates.first(where: { $0.config.service == "monday" }) else {
            XCTFail("Expected bundled Monday template")
            return
        }

        try await appState.addService(
            template: mondayTemplate,
            apiKey: apiKey,
            extraFieldValues: [:]
        )

        let serviceDir = appState.syncRootURL.appendingPathComponent("monday", isDirectory: true)
        let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
        let adapterConfig = try AdapterEngine.loadConfig(from: serviceDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: adapterURL.path))
        XCTAssertEqual(adapterConfig.enabled, true)
        XCTAssertEqual(adapterConfig.displayName, "Monday.com")

        let storedKey = await appState.platformServices.keychainManager.load(key: "api2file.monday.api-key")
        XCTAssertEqual(storedKey, apiKey)

        await appState.refresh()
        XCTAssertTrue(appState.services.contains(where: { $0.serviceId == "monday" }))
    }
}
