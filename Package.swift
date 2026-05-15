// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShellfishPoC",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ShellfishCore", path: "Sources/ShellfishCore"),
        .executableTarget(name: "Harness", path: "Sources/Harness"),
        .executableTarget(name: "HarnessS2", dependencies: ["ShellfishCore"], path: "Sources/HarnessS2"),
        .executableTarget(name: "HarnessS4", path: "Sources/HarnessS4"),
        .executableTarget(name: "ToolRunner", path: "Sources/ToolRunner"),
        .executableTarget(name: "AttackerObserver", path: "Sources/AttackerObserver"),
        .executableTarget(name: "Chat", dependencies: ["ShellfishCore"], path: "Sources/Chat"),
    ]
)
