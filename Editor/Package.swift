// swift-tools-version: 6.2
import Foundation
import PackageDescription

let adaEngineLocalPath = ProcessInfo.processInfo.environment["ADAENGINE_PACKAGE_PATH"] ?? ".."
let editorPackageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let adjacentAdaMCP = editorPackageURL.appendingPathComponent("../../AdaMCP").standardizedFileURL
let adaMCPURL = ProcessInfo.processInfo.environment["ADA_MCP_LOCAL_PATH"].map {
    URL(fileURLWithPath: $0, relativeTo: editorPackageURL).standardizedFileURL
} ?? (FileManager.default.fileExists(atPath: adjacentAdaMCP.appendingPathComponent("Package.swift").path) ? adjacentAdaMCP : nil)
let isAndroidStudio = ProcessInfo.processInfo.environment["ADAEDITOR_ANDROID"] == "1"
let sloppyRuntimeLocalPath = ProcessInfo.processInfo.environment["SLOPPY_RUNTIME_LOCAL_PATH"] ?? "../../Sloppy/Packages/SloppyRuntime"
let sloppyRuntimeURL = URL(fileURLWithPath: sloppyRuntimeLocalPath, relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent()).standardizedFileURL
// Desktop Windows has no SloppyRuntime target dependency. Resolving the mobile-only
// graph can nevertheless force an incompatible SwiftSyntax version into desktop builds.
#if os(Windows)
let hasSloppyRuntime = isAndroidStudio && FileManager.default.fileExists(atPath: sloppyRuntimeURL.appendingPathComponent("Package.swift").path)
#else
let hasSloppyRuntime = FileManager.default.fileExists(atPath: sloppyRuntimeURL.appendingPathComponent("Package.swift").path)
#endif
let sloppyRuntimePackage: [Package.Dependency] = hasSloppyRuntime
    ? [.package(name: "SloppyRuntimePortable", path: sloppyRuntimeURL.path)]
    : []
let sloppyRuntimeTarget: [Target.Dependency] = hasSloppyRuntime
    ? [
        .product(name: "SloppyRuntime", package: "SloppyRuntimePortable", condition: .when(platforms: [.iOS, .visionOS, .android])),
        .product(name: "Protocols", package: "SloppyRuntimePortable", condition: .when(platforms: [.iOS, .visionOS, .android])),
    ]
    : []
// AdaMCP's dependency graph includes Git revisions, so SwiftPM requires a revision here.
let adaMCPPackage: Package.Dependency = adaMCPURL.map {
    .package(name: "AdaMCP", path: $0.path)
} ?? .package(url: "https://github.com/AdaEngine/AdaMCP.git", revision: "ed7bb9076f9f8c91e2584ca9b7201df0e03defb1")

let engineSourceURL = URL(fileURLWithPath: adaEngineLocalPath, relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent()).standardizedFileURL
let gravityAOTPath = ProcessInfo.processInfo.environment["ADAENGINE_GRAVITY_PACKAGE_PATH"]
    ?? engineSourceURL.appendingPathComponent("Sources/gravity-lang").path
let gravityAOTPackage: [Package.Dependency] = [.package(name: "gravity-lang", path: gravityAOTPath)]
let gravityAOTTarget: [Target.Dependency] = [.product(name: "GravityAOT", package: "gravity-lang"), .product(name: "CGravity", package: "gravity-lang")]

if isAndroidStudio && !hasSloppyRuntime {
    fatalError("Android Studio requires SLOPPY_RUNTIME_LOCAL_PATH pointing to Sloppy/Packages/SloppyRuntime.")
}
let windowsIconResource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build-tools/AdaStudio.res").path
let windowsIconLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(atPath: windowsIconResource)
    ? [.unsafeFlags(["-Xlinker", windowsIconResource], .when(platforms: [.windows]))] : []

let package = Package(
    name: "AdaEditor",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v26),
        .macOS(.v15),
    ],
    products: [
        isAndroidStudio
            ? .library(name: "AdaStudioMobile", type: .dynamic, targets: ["AdaEditor"])
            : .executable(name: "AdaEditor", targets: ["AdaEditor"]),
        .executable(
            name: "gravity-lsp",
            targets: ["GravityLanguageServer"]
        ),
    ],
    dependencies: [
        .package(path: "StudioCore"),
        ProcessInfo.processInfo.environment["ADAEDITOR_SWIFTTERM_PACKAGE_PATH"].map { .package(name: "SwiftTerm", path: $0) }
            ?? .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(name: "AdaEngine", path: adaEngineLocalPath),
        .package(name: "AdaDebugging", path: "Debugging"),
        .package(name: "AdaPlayerConnect", path: "PlayerConnect"),
        adaMCPPackage,
        .package(url: "https://github.com/SpectralDragon/Yams.git", revision: "fb676da"),
        .package(url: "https://github.com/TeamSloppy/swift-acp", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "602.0.0"..<"604.0.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
    ] + sloppyRuntimePackage + gravityAOTPackage,
    targets: [
        .target(name: "CEditorTerminal", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "CAndroidStudio", dependencies: [
            .product(name: "CAndroid", package: "AdaEngine", condition: .when(platforms: [.android]))
        ]),
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
        makeEditorTarget(
            name: "AdaEditor",
            dependencies: [
                .product(name: "AdaStudioCore", package: "StudioCore"),
                .product(name: "AdaDebugging", package: "AdaDebugging"),
                .product(name: "AdaPlayerConnect", package: "AdaPlayerConnect"),
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "AdaSpine", package: "AdaEngine"),
                .product(name: "AdaA2UI", package: "AdaEngine"),
                .product(name: "AdaEngineEmbeddable", package: "AdaEngine"),
                .product(name: "AdaMultiplayer", package: "AdaEngine"),
                .product(name: "AdaScriptCompilerCore", package: "AdaEngine"),
                .product(name: "Math", package: "AdaEngine"),
                .product(name: "AdaMCPPlugin", package: "AdaMCP", condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .windows, .linux])),
                .product(name: "AdaMCPCore", package: "AdaMCP"),
                .product(name: "MCP", package: "AdaMCP"),
                .product(name: "ACP", package: "swift-acp", condition: .when(platforms: [.macOS])),
                .product(name: "ACPModel", package: "swift-acp", condition: .when(platforms: [.macOS, .windows])),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                "Yams",
                .product(name: "Crypto", package: "swift-crypto"),
                "AdaPackageManifestTool",
                "CEditorTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "GravityLanguageCore",
                .target(name: "CAndroidStudio", condition: .when(platforms: [.android])),
            ] + sloppyRuntimeTarget + gravityAOTTarget,
            exclude: [
                "Platforms/iOS/Info.plist",
                "Platforms/macOS/Info.plist",
            ],
            resources: [
                .copy("Assets")
            ],
            swiftSettings: editorSwiftSettings,
            linkerSettings: windowsIconLinkerSettings
        ),
        .testTarget(
            name: "AdaEditorTests",
            dependencies: [
                .product(name: "AdaDebugging", package: "AdaDebugging"),
                .product(name: "AdaPlayerConnect", package: "AdaPlayerConnect"),
                "AdaEditor",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "AdaSpine", package: "AdaEngine"),
                .product(name: "AdaMCPCore", package: "AdaMCP"),
                .product(name: "MCP", package: "AdaMCP"),
                "AdaPackageManifestTool",
                "GravityLanguageCore",
                "GravityLanguageServerProtocol",
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "AdaA2UI", package: "AdaEngine"),
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

private func makeEditorTarget(
    name: String,
    dependencies: [Target.Dependency],
    exclude: [String],
    resources: [Resource],
    swiftSettings: [SwiftSetting],
    linkerSettings: [LinkerSetting]
) -> Target {
    if isAndroidStudio {
        return .target(name: name, dependencies: dependencies, exclude: exclude, resources: resources, swiftSettings: swiftSettings, linkerSettings: linkerSettings)
    }
    return .executableTarget(name: name, dependencies: dependencies, exclude: exclude, resources: resources, swiftSettings: swiftSettings, linkerSettings: linkerSettings)
}
