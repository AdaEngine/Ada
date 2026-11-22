// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GreenValley",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "AdaEngine", path: "../../../..")],
    targets: [.executableTarget(name: "GreenValley", dependencies: [.product(name: "AdaEngine", package: "AdaEngine"), .product(name: "Math", package: "AdaEngine")])]
)
