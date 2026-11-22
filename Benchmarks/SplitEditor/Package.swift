// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SplitEditor",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "AdaEngine", path: "../..")],
    targets: [.executableTarget(name: "SplitEditor", dependencies: [.product(name: "AdaEngine", package: "AdaEngine")])]
)
