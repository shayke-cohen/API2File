import XCTest
@testable import API2FileiOSApp
import API2FileCore

@MainActor
final class IOSAdapterStoreTests: XCTestCase {
    func testSeededAdapterStoreIncludesWixTemplate() async throws {
        let appState = IOSAppState()
        try await appState.platformServices.adapterStore.seedIfNeeded()
        let templates = try await appState.platformServices.adapterStore.loadAll()

        XCTAssertTrue(
            templates.contains(where: { $0.config.service == "wix" }),
            "Expected iOS adapter store to expose the bundled Wix template"
        )
    }

    func testSeededAdapterStoreMatchesBundledTemplatesAndWixResources() async throws {
        let appState = IOSAppState()
        try await appState.platformServices.adapterStore.seedIfNeeded()
        let templates = try await appState.platformServices.adapterStore.loadAll()

        let adapterFiles = try FileManager.default.contentsOfDirectory(
            at: bundledAdaptersDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".adapter.json") }

        let bundledConfigs = try adapterFiles.map { url in
            try JSONDecoder().decode(AdapterConfig.self, from: Data(contentsOf: url))
        }
        let seededFiles = try FileManager.default.contentsOfDirectory(
            at: appState.platformServices.storageLocations.adaptersDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".adapter.json") }

        XCTAssertEqual(
            Set(seededFiles.map(\.lastPathComponent)),
            Set(adapterFiles.map(\.lastPathComponent)),
            "Expected iOS seeding to copy every bundled adapter file into the app-managed adapter directory"
        )

        let visibleBundledConfigs = bundledConfigs.filter { $0.hidden != true }

        XCTAssertEqual(
            Set(templates.map(\.config.service)),
            Set(visibleBundledConfigs.map(\.service)),
            "Expected iOS visible adapter templates to match the non-hidden bundled templates shipped in the repo"
        )

        let bundledWix = try XCTUnwrap(bundledConfigs.first(where: { $0.service == "wix" }))
        let seededWix = try XCTUnwrap(templates.first(where: { $0.config.service == "wix" }))
        XCTAssertEqual(
            seededWix.config.resources.map(\.name),
            bundledWix.resources.map(\.name),
            "Expected the iOS Wix adapter template to expose the same resource set as the bundled core template"
        )
    }

    private var bundledAdaptersDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/API2FileCore/Resources/Adapters", isDirectory: true)
    }
}
