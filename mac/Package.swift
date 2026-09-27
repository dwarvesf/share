// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShareBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ShareBarCore"),
        .executableTarget(name: "ShareBar", dependencies: ["ShareBarCore"]),
        .testTarget(name: "ShareBarCoreTests", dependencies: ["ShareBarCore"]),
    ]
)
