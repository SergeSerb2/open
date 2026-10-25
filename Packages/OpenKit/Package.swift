// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenModel", targets: ["OpenModel"]),
        .library(name: "OpenStore", targets: ["OpenStore"]),
        .library(name: "OpenImport", targets: ["OpenImport"]),
        .executable(name: "openkit", targets: ["openkit"]),
    ],
    targets: [
        .target(name: "OpenModel"),
        .target(name: "OpenStore", dependencies: ["OpenModel"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "OpenImport", dependencies: ["OpenModel"]),
        .executableTarget(name: "openkit", dependencies: ["OpenModel", "OpenStore", "OpenImport"]),
    ]
)
