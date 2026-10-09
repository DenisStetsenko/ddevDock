// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ddevDock",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ddevDock",
            path: "Sources/ddevDock"
        )
    ]
)
