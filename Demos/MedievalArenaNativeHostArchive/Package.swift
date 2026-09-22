// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MedievalArena",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MedievalArena", targets: ["MedievalArena"])
    ],
    dependencies: [
        .package(name: "AdaEngine", path: "../..")
    ],
    targets: [
        .target(
            name: "MedievalArenaGame",
            dependencies: [
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "AdaMultiplayer", package: "AdaEngine")
            ],
            resources: [.copy("../../Assets")],
            plugins: [.plugin(name: "AdaScriptBuildPlugin", package: "AdaEngine")]
        ),
        .executableTarget(
            name: "MedievalArena",
            dependencies: [
                "MedievalArenaGame",
                .product(name: "AdaEngine", package: "AdaEngine")
            ]
        ),
        .testTarget(
            name: "MedievalArenaGameTests",
            dependencies: ["MedievalArenaGame"]
        )
    ]
)
