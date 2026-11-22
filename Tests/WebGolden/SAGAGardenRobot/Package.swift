// swift-tools-version: 6.2
import Foundation
import PackageDescription

guard let engine = ProcessInfo.processInfo.environment["ADAENGINE_GARDEN_ENGINE_PATH"] else {
    fatalError("Set ADAENGINE_GARDEN_ENGINE_PATH to the AdaEngine checkout")
}

let package = Package(
    name: "GardenRobotBrowserSmoke",
    dependencies: [.package(name: "AdaEngine", path: engine)],
    targets: [
        .executableTarget(
            name: "GardenRobot",
            dependencies: [.product(name: "AdaEngine", package: "AdaEngine")],
            path: ".",
            sources: ["GardenRobot.swift"],
            resources: [.copy("GardenRobot.glb")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--export-if-defined=main",
                    "-Xlinker", "--export-if-defined=__main_argc_argv",
                    "-Xlinker", "--strip-debug",
                ], .when(platforms: [.wasi]))
            ]
        )
    ]
)
