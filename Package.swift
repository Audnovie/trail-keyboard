// swift-tools-version:5.9
// The typing engine on its own, so its tests can run with `swift test` on a Mac.
// The iPhone app and keyboard are built from project.yml (XcodeGen) and use the same sources.
import PackageDescription

let package = Package(
    name: "TrailEngine",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "TrailEngine", targets: ["TrailEngine"]),
    ],
    targets: [
        .target(name: "TrailEngine", path: "Shared/Engine"),
        .testTarget(
            name: "EngineTests",
            dependencies: ["TrailEngine"],
            path: "Tests/EngineTests",
            exclude: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
