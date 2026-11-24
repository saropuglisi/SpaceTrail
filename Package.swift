// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceTrail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceTrail", targets: ["SpaceTrail"]),
        .executable(name: "SpaceTrailBroker", targets: ["SpaceTrailBroker"])
    ],
    targets: [
        .target(name: "SpaceTrailCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SpaceTrailBroker", dependencies: ["SpaceTrailCore"]),
        .executableTarget(name: "SpaceTrail", dependencies: ["SpaceTrailCore"])
    ],
    swiftLanguageModes: [.v5]
)
