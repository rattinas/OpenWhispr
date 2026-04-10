// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TalkIsCheap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TalkIsCheap",
            path: "Sources/TalkIsCheap",
            resources: [.copy("../../Resources")]
        )
    ]
)
