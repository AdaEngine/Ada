// swift-tools-version: 6.2
import Foundation
import PackageDescription

let adaMCPLocalPath = ProcessInfo.processInfo.environment["ADA_MCP_LOCAL_PATH"] ?? "../../AdaMCP"
let adaMCPPackage: Package.Dependency =
    true /*ProcessInfo.processInfo.environment["ADA_MCP_LOCAL"] == "1"*/
    ? .package(name: "AdaMCP", path: adaMCPLocalPath)
    : .package(url: "https://github.com/AdaEngine/AdaMCP.git", branch: "main")

let package = Package(
    name: "AdaEditor",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2),
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "AdaEditor",
            targets: ["AdaEditor"]
        ),
        .executable(
            name: "gravity-lsp",
            targets: ["GravityLanguageServer"]
        ),
    ],
    dependencies: [
        .package(name: "AdaEngine", path: ".."),
        .package(name: "AdaDebugging", path: "Debugging"),
        .package(name: "AdaPlayerConnect", path: "PlayerConnect"),
        adaMCPPackage,
        .package(url: "https://github.com/SpectralDragon/Yams.git", revision: "fb676da"),
        .package(url: "https://github.com/TeamSloppy/swift-acp", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
    ],
    targets: [
        .target(
            name: "GravityLanguageCore",
            dependencies: [
                .product(name: "AdaScriptCompilerCore", package: "AdaEngine")
            ]
        ),
        .target(
            name: "GravityLanguageServerProtocol",
            dependencies: [
                "GravityLanguageCore"
            ]
        ),
        .executableTarget(
            name: "GravityLanguageServer",
            dependencies: [
                "GravityLanguageServerProtocol"
            ]
        ),
        .target(
            name: "AdaPackageManifestTool",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "AdaPackageTool",
            dependencies: [
                "AdaPackageManifestTool"
            ]
        ),
        .executableTarget(
            name: "AdaEditor",
            dependencies: [
                .product(name: "AdaDebugging", package: "AdaDebugging"),
                .product(name: "AdaPlayerConnect", package: "AdaPlayerConnect"),
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "AdaMultiplayer", package: "AdaEngine"),
                .product(name: "AdaScriptCompilerCore", package: "AdaEngine"),
                .product(name: "Math", package: "AdaEngine"),
                .product(name: "AdaMCPPlugin", package: "AdaMCP"),
                .product(name: "AdaMCPCore", package: "AdaMCP"),
                .product(name: "MCP", package: "AdaMCP"),
                .product(name: "ACP", package: "swift-acp", condition: .when(platforms: [.macOS])),
                .product(name: "ACPModel", package: "swift-acp", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                "Yams",
                "AdaPackageManifestTool",
                "GravityLanguageCore",
            ],
            exclude: [
                "Platforms/iOS/Info.plist",
                "Platforms/macOS/Info.plist",
            ],
            resources: [
                .copy("Assets")
            ],
            swiftSettings: editorSwiftSettings
        ),
        .testTarget(
            name: "AdaEditorTests",
            dependencies: [
                .product(name: "AdaDebugging", package: "AdaDebugging"),
                .product(name: "AdaPlayerConnect", package: "AdaPlayerConnect"),
                "AdaEditor",
                .product(name: "AdaMCPCore", package: "AdaMCP"),
                .product(name: "MCP", package: "AdaMCP"),
                "AdaPackageManifestTool",
                "GravityLanguageCore",
                "GravityLanguageServerProtocol",
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "Math", package: "AdaEngine"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
            ],
            exclude: [
                "Fixtures"
            ]
        ),
    ]
)

let editorSwiftSettings: [SwiftSetting] = [
    .define("MACOS", .when(platforms: [.macOS])),
    .define("WINDOWS", .when(platforms: [.windows])),
    .define("IOS", .when(platforms: [.iOS])),
    .define("TVOS", .when(platforms: [.tvOS])),
    .define("VISIONOS", .when(platforms: [.visionOS])),
    .define("ANDROID", .when(platforms: [.android])),
    .define("LINUX", .when(platforms: [.linux])),
    .define("DARWIN", .when(platforms: [.iOS, .macOS, .tvOS, .watchOS, .visionOS])),
    .define("METAL", .when(platforms: [.iOS, .macOS, .tvOS, .watchOS, .visionOS])),
    .define("ENABLE_DEBUG_DYLIB", .when(configuration: .debug)),
    .define("EDITOR_DEBUG", .when(configuration: .debug)),
    .define("EDITOR_MACOS", .when(platforms: [.macOS])),
    .define("EDITOR_WINDOWS", .when(platforms: [.windows])),
    .define("EDITOR_IOS", .when(platforms: [.iOS])),
    .define("EDITOR_TVOS", .when(platforms: [.tvOS])),
    .define("EDITOR_ANDROID", .when(platforms: [.android])),
    .define("EDITOR_LINUX", .when(platforms: [.linux])),
    .enableUpcomingFeature("MemberImportVisibility"),
    .strictMemorySafety(),
    .unsafeFlags(["-Xfrontend", "-validate-tbd-against-ir=none"]),
]
