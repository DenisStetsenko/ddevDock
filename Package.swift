// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ddevDock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ddevDock",
            path: "Sources/ddevDock",
            // AppIcon.icns is for Finder; the Makefile copies it into the .app,
            // it is not needed inside Bundle.module.
            exclude: ["Resources/AppIcon.icns"],
            resources: [.copy("Resources/icon.svg")],
            // Swift 6 strict concurrency would need @MainActor plumbing; not worth it here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
