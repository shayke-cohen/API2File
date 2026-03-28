import XCTest
@testable import API2FileCore

final class StorageLocationsTests: XCTestCase {
    func testCurrentUserHomeDirectoryPrefersPosixHomeOnMacOS() {
        #if os(macOS)
        let resolved = StorageLocations.currentUserHomeDirectory(
            environmentHome: "/Users/shayco/Library/Containers/com.api2file.app/Data",
            posixHomeDirectory: "/Users/shayco"
        )

        XCTAssertEqual(resolved.path, "/Users/shayco")
        #else
        throw XCTSkip("macOS-specific path resolution")
        #endif
    }

    func testCurrentUserHomeDirectoryFallsBackToEnvironmentHome() {
        let resolved = StorageLocations.currentUserHomeDirectory(
            environmentHome: "/tmp/api2file-home",
            posixHomeDirectory: nil
        )

        XCTAssertEqual(resolved.path, "/tmp/api2file-home")
    }
}
