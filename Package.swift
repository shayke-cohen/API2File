// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "API2File",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "API2FileCore",
            targets: ["API2FileCore"]
        ),
        .executable(
            name: "API2FileApp",
            targets: ["API2FileApp"]
        ),
    ],
    targets: [
        .target(
            name: "API2FileCore",
            path: "Sources/API2FileCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "API2FileApp",
            dependencies: ["API2FileCore"],
            path: "Sources/API2FileApp"
        ),
        .testTarget(
            name: "API2FileCoreTests",
            dependencies: ["API2FileCore"],
            path: "Tests/API2FileCoreTests"
        ),
    ]
)
