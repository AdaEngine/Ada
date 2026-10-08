// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaDebugging",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AdaDebugging", targets: ["AdaDebugging"])],
    targets: [
        .target(name: "AdaDebugging"),
        .testTarget(name: "AdaDebuggingTests", dependencies: ["AdaDebugging"])
    ]
)
