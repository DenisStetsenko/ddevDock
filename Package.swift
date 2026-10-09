// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ddevDock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ddevDock",
            path: "Sources/ddevDock",
            resources: [.copy("Resources/icon.svg")],
            // Swift 6 strict concurrency would need @MainActor plumbing; not worth it here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
