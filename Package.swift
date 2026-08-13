// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "InboxCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FlickApp",
            dependencies: ["InboxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "flick",
            dependencies: ["InboxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
