// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaPlayerConnect",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AdaPlayerConnect", targets: ["AdaPlayerConnect"])],
    targets: [
        .target(name: "AdaPlayerConnect"),
        .testTarget(name: "AdaPlayerConnectTests", dependencies: ["AdaPlayerConnect"])
    ]
)
