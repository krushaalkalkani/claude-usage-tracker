// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, UI-free logic. Everything that could be wrong lives here so it can be tested.
        .target(
            name: "ClaudeUsageCore",
            path: "ClaudeUsage",
            exclude: ["App", "Views", "Tests", "Resources"],
            sources: ["Models", "Services", "Analytics", "Notifications"]
        ),
        // The menu bar app itself.
        .executableTarget(
            name: "ClaudeUsageApp",
            dependencies: ["ClaudeUsageCore"],
            path: "ClaudeUsage",
            exclude: ["Models", "Services", "Analytics", "Notifications", "Tests", "Resources"],
            sources: ["App", "Views"]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            path: "ClaudeUsage/Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
