// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexTip",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexTip", targets: ["CodexTip"])],
    targets: [
        .target(name: "CodexTipCore"),
        .executableTarget(name: "CodexTip", dependencies: ["CodexTipCore"]),
        .testTarget(name: "CodexTipCoreTests", dependencies: ["CodexTipCore"])
    ]
)
