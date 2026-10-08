// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UIInventoryExample",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "GameUI", targets: ["GameUI"])],
    dependencies: [.package(name: "AdaEngine", path: "../../..")],
    targets: [.target(name: "GameUI", dependencies: [.product(name: "AdaEngine", package: "AdaEngine")])]
)
