// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceTrail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceTrail", targets: ["SpaceTrail"]),
        .executable(name: "SpaceTrailBroker", targets: ["SpaceTrailBroker"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "SpaceTrailCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SpaceTrailBroker", dependencies: ["SpaceTrailCore"]),
        .executableTarget(name: "SpaceTrail", dependencies: ["SpaceTrailCore", "ZIPFoundation"])
    ],
    swiftLanguageModes: [.v5]
)
