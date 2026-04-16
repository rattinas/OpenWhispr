// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TalkIsCheap",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "TalkIsCheap",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/TalkIsCheap",
            resources: [.copy("../../Resources")]
        )
    ]
)
