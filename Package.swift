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
        .executable(
            name: "api2file-demo",
            targets: ["API2FileDemo"]
        ),
        .executable(
            name: "api2file",
            targets: ["API2FileCLI"]
        ),
        .executable(
            name: "api2file-mcp",
            targets: ["API2FileMCP"]
        ),
    ],
    dependencies: [
        .package(path: "../appxray/packages/sdk-ios"),
    ],
    targets: [
        .target(
            name: "API2FileCore",
            path: "Sources/API2FileCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "API2FileApp",
            dependencies: [
                "API2FileCore",
                .product(name: "AppXray", package: "sdk-ios"),
            ],
            path: "Sources/API2FileApp"
        ),
        .executableTarget(
            name: "API2FileDemo",
            dependencies: ["API2FileCore"],
            path: "Sources/API2FileDemo"
        ),
        .executableTarget(
            name: "API2FileCLI",
            dependencies: ["API2FileCore"],
            path: "Sources/API2FileCLI"
        ),
        .executableTarget(
            name: "API2FileMCP",
            dependencies: [],
            path: "Sources/API2FileMCP"
        ),
        .testTarget(
            name: "API2FileCoreTests",
            dependencies: ["API2FileCore"],
            path: "Tests/API2FileCoreTests"
        ),
    ]
)
