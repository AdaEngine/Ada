// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SponzaDemo",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "AdaEngine", path: "../..")],
    targets: [
        .executableTarget(
            name: "SponzaDemo",
            dependencies: ["SponzaCamera", .product(name: "AdaEngine", package: "AdaEngine"), .product(name: "Math", package: "AdaEngine")],
            path: ".",
            exclude: ["README.md", "Tests", "Camera"],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility"), .strictMemorySafety()]
        ),
        .target(name: "SponzaCamera", dependencies: [.product(name: "AdaTransform", package: "AdaEngine"), .product(name: "Math", package: "AdaEngine")], path: "Camera"),
        .testTarget(name: "SponzaDemoTests", dependencies: ["SponzaCamera", .product(name: "AdaTransform", package: "AdaEngine")], path: "Tests")
    ]
)
