// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenModel", targets: ["OpenModel"]),
        .library(name: "OpenRouting", targets: ["OpenRouting"]),
        .library(name: "OpenSleep", targets: ["OpenSleep"]),
        .library(name: "OpenStore", targets: ["OpenStore"]),
        .library(name: "OpenImport", targets: ["OpenImport"]),
        .library(name: "OpenSuggest", targets: ["OpenSuggest"]),
        .library(name: "OpenCommands", targets: ["OpenCommands"]),
        .library(name: "OpenScripting", targets: ["OpenScripting"]),
        .executable(name: "openkit", targets: ["openkit"]),
        .executable(name: "commands-dump", targets: ["commands-dump"]),
    ],
    targets: [
        .target(name: "OpenModel"),
        .target(name: "OpenSleep", dependencies: ["OpenModel"]),
        .target(name: "OpenRouting", dependencies: ["OpenModel"]),
        .target(name: "OpenStore", dependencies: ["OpenModel"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "OpenImport", dependencies: ["OpenModel"]),
        .target(name: "OpenSuggest", dependencies: ["OpenModel", "OpenStore"], resources: [.copy("Resources/public_suffix_list.dat")]),
        .target(name: "OpenCommands", dependencies: ["OpenModel", "OpenSuggest"], resources: [.copy("Resources/expected-menu.json")], linkerSettings: [.linkedFramework("Carbon")]),
        .target(name: "OpenScripting", dependencies: ["OpenModel", "OpenCommands"]),
        .executableTarget(name: "openkit", dependencies: ["OpenModel", "OpenStore", "OpenImport", "OpenSuggest", "OpenRouting", "OpenSleep"], resources: [.copy("Resources/sleep-schema1.json")]),
        .executableTarget(name: "commands-dump", dependencies: ["OpenCommands", "OpenSuggest"]),
    ]
)
