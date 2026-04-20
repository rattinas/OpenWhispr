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
            resources: [.copy("../../Resources")],
            // Install-time we embed Sparkle.framework into
            // Contents/Frameworks/; the binary lives in Contents/MacOS/. Tell
            // dyld to look one level up + into Frameworks so the framework
            // resolves at runtime. Without this, launches from /Applications
            // crash with "Library not loaded: @rpath/Sparkle.framework/...".
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        )
    ]
)
