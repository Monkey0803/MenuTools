// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuTools",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "MenuTools",
            path: "Sources/MenuTools"
        ),
        .testTarget(
            name: "MenuToolsTests",
            dependencies: ["MenuTools"],
            path: "Tests/MenuToolsTests"
        )
    ]
)
