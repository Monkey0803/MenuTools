// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuTools",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // Sparkle 使用官方发布的 SPM 二进制包，避免源码构建带来的额外发布工具链依赖。
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "MenuTools",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MenuTools"
        ),
        .testTarget(
            name: "MenuToolsTests",
            dependencies: ["MenuTools"],
            path: "Tests/MenuToolsTests"
        )
    ]
)
