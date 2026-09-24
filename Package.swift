// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation
import CompilerPluginSupport

#if canImport(AppleProductTypes)
import AppleProductTypes
#endif

let isHeadlessCIEnabled: Bool = {
    let environment = ProcessInfo.processInfo.environment
    let headlessValue = environment["ADAENGINE_HEADLESS"]?.lowercased()
    let disableSwanValue = environment["ADAENGINE_DISABLE_SWAN"]?.lowercased()
    let enabledValues: Set<String> = ["1", "true", "yes", "on"]

    return headlessValue.map(enabledValues.contains) == true
        || disableSwanValue.map(enabledValues.contains) == true
}()

let isWebExportEnabled: Bool = {
    let webExportValue = ProcessInfo.processInfo.environment["ADAENGINE_WEB_EXPORT"]?.lowercased()
    let enabledValues: Set<String> = ["1", "true", "yes", "on"]

    return webExportValue.map(enabledValues.contains) == true
}()

#if canImport(Darwin)
import Darwin.C

/// Only xcode can import AppleProductTypes and we can use it as checker
#if canImport(AppleProductTypes)
let isWGPUEnabled = isWebExportEnabled // We can't build wgpu from xcode, except web export builds.
#else
let isWGPUEnabled = isWebExportEnabled
#endif

#else

#if os(Linux)
import Glibc
#endif

#if os(Windows)
import WinSDK
#endif

let isWGPUEnabled = !isHeadlessCIEnabled
#endif

extension String {
    static let wgpuTrait = "WGPU_ENABLED"
}

let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS, .watchOS, .visionOS]

#if canImport(Darwin)
let miniaudioSources = isWebExportEnabled ? ["miniaudio.c"] : ["miniaudio.c", "miniaudio_apple.m"]
#else
let miniaudioSources = ["miniaudio.c"]
#endif

var products: [Product] = [
    .executable(name: "AdaWebPlayer", targets: ["AdaWebPlayer"]),
    .executable(name: "AdaWebPlayerPackager", targets: ["AdaWebPlayerPackager"]),
    .library(name: "AdaUIDescription", targets: ["AdaUIDescription"]),
    .library(
        name: "AdaEngine",
        targets: ["AdaEngine"]
    ),
    .library(
        name: "AdaApp",
        targets: ["AdaApp"]
    ),
    .library(
        name: "AdaECS",
        targets: ["AdaECS"]
    ),
    .library(
        name: "AdaMultiplayer",
        targets: ["AdaMultiplayer"]
    ),
    .library(
        name: "AdaScripting",
        targets: ["AdaScripting"]
    ),
    .library(
        name: "AdaScriptCompilerCore",
        targets: ["AdaScriptCompilerCore"]
    ),
    .library(
        name: "AdaUI",
        targets: ["AdaUI"]
    ),
    .library(
        name: "AdaRender",
        targets: ["AdaRender"]
    ),
    .library(
        name: "AdaScene",
        targets: ["AdaScene"]
    ),
    .library(
        name: "AdaSprite",
        targets: ["AdaSprite"]
    ),
    .library(
        name: "AdaText",
        targets: ["AdaText"]
    ),
    .library(
        name: "AdaTransform",
        targets: ["AdaTransform"]
    ),
    .library(
        name: "AdaUtils",
        targets: ["AdaUtils"]
    ),
    .library(
        name: "Math",
        targets: ["Math"]
    ),
    .library(
        name: "AdaAnimation",
        targets: ["AdaAnimation"]
    ),
    .library(
        name: "AdaEngineEmbeddable",
        targets: ["AdaEngineEmbeddable"]
    ),
    .library(
        name: "AdaWeb",
        targets: ["AdaWeb"]
    ),
    .plugin(name: "WebGPUBuildPlugin", targets: [
        "WebGPUBuildPlugin"
    ]),
    .executable(
        name: "TextureAtlasBuilderTool",
        targets: ["TextureAtlasBuilderTool"]
    ),
    .plugin(name: "TextureAtlasBuildPlugin", targets: [
        "TextureAtlasBuildPlugin"
    ]),
    .plugin(name: "TextureAtlasCommandPlugin", targets: [
        "TextureAtlasCommandPlugin"
    ]),
    .plugin(name: "AdaScriptBuildPlugin", targets: [
        "AdaScriptBuildPlugin"
    ])
]

// MARK: - Targets

// MARK: Editor Target

var commonPlugins: [Target.PluginUsage] = []

#if os(macOS) || os(Linux)
if !isWebExportEnabled {
    commonPlugins.append(
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
    )
}
#endif

var swiftSettings: [SwiftSetting] = [
    .define("MACOS", .when(platforms: [.macOS])),
    .define("WINDOWS", .when(platforms: [.windows])),
    .define("IOS", .when(platforms: [.iOS])),
    .define("TVOS", .when(platforms: [.tvOS])),
    .define("VISIONOS", .when(platforms: [.visionOS])),
    .define("ANDROID", .when(platforms: [.android])),
    .define("LINUX", .when(platforms: [.linux])),
    .define("DARWIN", .when(platforms: applePlatforms)),
    .define("METAL", .when(platforms: applePlatforms)),
    .define("WEBGPU_ENABLED", .when(traits: [.wgpuTrait])),
    .define("WASM", .when(platforms: [.wasi])),
    .define("BROWSER", .when(platforms: [.wasi])),
    .define("ENABLE_DEBUG_DYLIB", .when(configuration: .debug)),
    .define("ENABLE_RUN_IN_CONCURRENCY", .when(platforms: [.windows, .wasi, .android, .linux])),
    .enableUpcomingFeature("MemberImportVisibility"),
    .strictMemorySafety(),
    .unsafeFlags(["-Xfrontend", "-validate-tbd-against-ir=none"]),
]

let wasmExecutableLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xclang-linker",
        "-mexec-model=reactor",
        "-Xlinker",
        "--export-if-defined=main",
        "-Xlinker",
        "--export-if-defined=__main_argc_argv"
    ], .when(platforms: [.wasi]))
]

// MARK: Ada Engine SDK

var adaEngineSwiftSettings = swiftSettings

var adaEngineDependencies: [Target.Dependency] = [
    "Math",
    .product(name: "Collections", package: "swift-collections"),
    .product(name: "BitCollections", package: "swift-collections"),
    "AdaApp",
    "AdaECS",
    "AdaAnimation",
    "AdaUI",
    "AdaEngineMacros",
    "AdaAssets",
    "AdaPlatform",
    "AdaAudio",
    "AdaCorePipelines",
    "AdaTransform",
    "AdaRender",
    "AdaText",
    "AdaInput",
    "AdaScene",
    "AdaScripting",
    "AdaSprite",
    "AdaTilemap",
    "AdaPhysics"
]

#if os(Linux)
adaEngineDependencies += ["X11"]
#endif

var adaRenderDependencies: [Target.Dependency] = [
    "AdaApp",
    "AdaECS",
    "AdaAssets",
    "AdaTransform",
    "Math",
    .product(
        name: "Yams",
        package: "Yams",
        condition: .when(platforms: applePlatforms + [.linux, .windows, .android])
    ),
    "SPIRV-Cross",
    "SPIRVCompiler",
    "libpng",
    .product(
        name: "Subprocess",
        package: "swift-subprocess",
        condition: .when(platforms: [
            .macOS,
            .linux,
            .windows
        ], traits: [
            .wgpuTrait
        ])
    ),
    .product(
        name: "JavaScriptKit",
        package: "JavaScriptKit",
        condition: .when(platforms: [.wasi])
    ),
]

if !isHeadlessCIEnabled {
    adaRenderDependencies.append(
        .product(
            name: "WebGPU",
            package: "swan",
            condition: .when(traits: [
                .wgpuTrait
            ])
        )
    )
}

let adaEngineTarget: Target = .adaTarget(
    name: "AdaEngine",
    dependencies: adaEngineDependencies,
    resources: [
        .copy("Assets/Images")
    ],
    cSettings: [
        .define("GL_SILENCE_DEPRECATION")
    ],
    swiftSettings: adaEngineSwiftSettings,
    plugins: commonPlugins
)

let adaEngineEmbeddable: Target = .adaTarget(
    name: "AdaEngineEmbeddable",
    dependencies: [
        "AdaEngine",
        "AdaEngineMacros"
    ]
)

let adaEngineMacros: Target = .macro(
    name: "AdaEngineMacros",
    dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
    ],
)

// MARK: Other Targets

var targets: [Target] = [
    adaEngineTarget,
    adaEngineEmbeddable,
    adaEngineMacros,
    .adaTarget(name: "Math"),
    .adaTarget(
        name: "AdaApp",
        dependencies: [
            "AdaUtils",
            "AdaECS",
            .product(
                name: "JavaScriptEventLoop",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaPlatform",
        dependencies: [
            "AdaUtils",
            "AdaECS",
            "AdaApp",
            "AdaUI",
            .product(
                name: "JavaScriptKit",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptEventLoop",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaMultiplayer",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "AdaEngineMacros",
            "AdaTransform",
            "AdaUtils",
            "Math",
            .product(
                name: "JavaScriptKit",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptFoundationCompat",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaECS",
        dependencies: [
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "BitCollections", package: "swift-collections"),
            .product(name: "Atomics", package: "swift-atomics"),
            "AdaEngineMacros",
            "AdaUtils",
            "Math"
        ],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "AdaScriptCompilerCore",
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaScripting",
        dependencies: [
            "AdaScriptCompilerCore",
            "AdaApp",
            "AdaAssets",
            "AdaECS",
            "AdaInput",
            "AdaMultiplayer",
            "AdaScene",
            "AdaUI",
            .product(name: "Gravity", package: "gravity-lang")
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaUtils",
        dependencies: [
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "BitCollections", package: "swift-collections"),
            "AdaEngineMacros",
            "Math",
            .product(
                name: "JavaScriptEventLoop",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaAnimation",
        dependencies: [
            "AdaECS",
            "AdaUtils",
            "Math"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaCorePipelines",
        dependencies: [
            "AdaECS",
            "AdaApp",
            "AdaRender",
            "AdaUtils",
            "Math"
        ],
        resources: [
            .copy("Assets/Shaders")
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaUtilsTesting",
        dependencies: [
            "AdaUtils"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaAssets",
        dependencies: [
            "AdaApp",
            "AdaUtils",
            "Math",
            .product(
        name: "Yams",
        package: "Yams",
        condition: .when(platforms: applePlatforms + [.linux, .windows, .android])
    ),
            .product(
                name: "JavaScriptKit",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptFoundationCompat",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaAudio",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "AdaUtils",
            "AdaAssets",
            "AdaTransform",
            "miniaudio",
            "Math",
            .product(name: "Atomics", package: "swift-atomics")
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaTransform",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "Math"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaRender",
        dependencies: adaRenderDependencies,
        resources: [
            .copy("Assets/Shaders")
        ],
        swiftSettings: swiftSettings,
        plugins: commonPlugins
    ),
    .adaTarget(
        name: "AdaText",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "AdaTransform",
            "Math",
            "AdaRender",
            "AtlasFontGenerator",
            "AdaTextShaper",
            .product(name: "Markdown", package: "swift-markdown"),
        ],
        resources: [
            .copy("Assets")
        ],
        swiftSettings: swiftSettings
    ),
    .target(name: "AdaUIDescription", dependencies: [.product(name: "Yams", package: "Yams")], swiftSettings: swiftSettings),
    .testTarget(name: "AdaUIDescriptionTests", dependencies: ["AdaUIDescription"]),
    .adaTarget(
        name: "AdaUI",
        dependencies: [
            "AdaUIDescription",
            "AdaAssets",
            "AdaAnimation",
            "AdaApp",
            "AdaECS",
            "AdaTransform",
            "AdaText",
            "AdaUtils",
            "Math",
            "AdaRender",
            "AdaCorePipelines",
            "AdaInput",
            "AdaEngineMacros",
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaInput",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "AdaTransform",
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaScene",
        dependencies: [
            "AdaApp",
            "AdaECS",
            "AdaAnimation",
            "box2d",
            "AdaTransform",
            "AdaText",
            "AdaAudio",
            "AdaCorePipelines",
            "AdaRender",
            "AdaUI",
            "AdaPhysics"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaTilemap",
        dependencies: [
            "AdaApp",
            "AdaAssets",
            "AdaECS",
            "Math",
            "AdaPhysics",
            "AdaSprite"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaPhysics",
        dependencies: [
            "AdaApp",
            "AdaAssets",
            "AdaECS",
            "Math",
            "box2d",
            "box3d",
            "AdaRender",
            "AdaCorePipelines"
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaSprite",
        dependencies: [
            "AdaApp",
            "AdaAssets",
            "AdaECS",
            "AdaText",
            "AdaUtils",
            "Math",
            "AdaRender",
            "AdaCorePipelines"
        ],
        resources: [
            .copy("Assets")
        ],
        swiftSettings: swiftSettings
    ),
    .adaTarget(
        name: "AdaWeb",
        dependencies: [
            "AdaApp",
            "AdaAssets",
            "AdaPlatform",
            "AdaRender",
            "AdaUI",
            .product(
                name: "JavaScriptKit",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptEventLoop",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            )
        ],
        swiftSettings: swiftSettings
    ),
]

targets.append(
    .executableTarget(
        name: "AdaWebPlayerPackager",
        dependencies: ["AdaScriptCompilerCore"],
        path: "Tools/AdaWebPlayerPackager"
    )
)

targets.append(
    .executableTarget(
        name: "AdaWebPlayer",
        dependencies: [
            "AdaEngine", "AdaScriptCompilerCore",
            .product(name: "Yams", package: "Yams"),
            "AdaMultiplayer",
            .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi]))
        ],
        path: "Tools/AdaWebPlayer",
        linkerSettings: wasmExecutableLinkerSettings + [
            .unsafeFlags(["-Xlinker", "--strip-debug"], .when(platforms: [.wasi], configuration: .release))
        ]
    )
)

if isWebExportEnabled {
    products.append(
        .plugin(name: "AdaWebExportPlugin", targets: [
            "AdaWebExportPlugin"
        ])
    )

    targets.append(
        .executableTarget(
            name: "AdaShaderTranspilerTool",
            dependencies: [
                "SPIRVCompiler"
            ],
            path: "Plugins/AdaShaderTranspilerTool"
        )
    )

    targets.append(
        .plugin(
            name: "AdaWebExportPlugin",
            capability: .command(
                intent: .custom(
                    verb: "export-web",
                    description: "Export an AdaEngine executable target as a browser WebAssembly app"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Write the exported web app bundle to the requested output directory"),
                    .allowNetworkConnections(scope: .all(), reason: "Download Dawn/Tint when Tint is not installed and shaders need WGSL generation")
                ]
            ),
            dependencies: [
                .target(name: "AdaShaderTranspilerTool")
            ],
            path: "Plugins/AdaWebExportPlugin"
        )
    )
}

targets.append(
    .plugin(
        name: "WebGPUBuildPlugin",
        capability: .buildTool(),
        dependencies: []
    )
)

targets.append(
    .executableTarget(
        name: "TextureAtlasBuilderTool",
        dependencies: ["AdaRender"],
        path: "Plugins/TextureAtlasBuilderTool",
        swiftSettings: swiftSettings
    )
)

targets.append(
    .plugin(
        name: "TextureAtlasBuildPlugin",
        capability: .buildTool(),
        dependencies: [
            .target(name: "TextureAtlasBuilderTool")
        ],
        path: "Plugins/TextureAtlasBuildPlugin"
    )
)

targets.append(
    .plugin(
        name: "TextureAtlasCommandPlugin",
        capability: .command(
            intent: .custom(
                verb: "build-texture-atlas",
                description: "Run TextureAtlasBuilderTool (pass --config and --output-swift)"
            ),
            permissions: []
        ),
        dependencies: [
            .target(name: "TextureAtlasBuilderTool")
        ],
        path: "Plugins/TextureAtlasCommandPlugin"
    )
)

targets.append(
    .executableTarget(
        name: "AdaScriptGeneratorTool",
        dependencies: ["AdaScriptCompilerCore"],
        path: "Plugins/AdaScriptGeneratorTool"
    )
)

targets.append(
    .plugin(
        name: "AdaScriptBuildPlugin",
        capability: .buildTool(),
        dependencies: [
            .target(name: "AdaScriptGeneratorTool")
        ],
        path: "Plugins/AdaScriptBuildPlugin"
    )
)

// MARK: Build Plugins
if isWGPUEnabled {

    targets.append(
        .plugin(
            name: "WebGPUTintPlugin",
            capability: .command(
                intent: .custom(verb: "build-tint", description: "Build Tint compiler from Dawn repository"),
                permissions: [
                    .allowNetworkConnections(scope: .all(), reason: "Download dawn from github")
                ]
            ),
            dependencies: []
        )
    )
}

// MARK: Extra

#if os(Android) || os(Linux)
targets += [
    .testTarget(name: "AdaScriptCompilerCoreTests", dependencies: ["AdaScriptCompilerCore"]),
    .systemLibrary(
        name: "X11",
        pkgConfig: "x11",
        providers: [
            .apt(["libx11-dev"])
        ]),
]
#endif

// MARK: - CXX Internal Targets

targets += [

    // Box2d

    .target(
        name: "box2d",
        exclude: [
            "shared",
            "docs",
            "samples",
            "test",
            "benchmark",
            "extern",
            "build.bat",
            "build.sh",
            "build_emscripten.sh",
            "CMakeLists.txt",
            "deploy_docs.sh",
            "LICENSE"
        ],
        publicHeadersPath: "include",
        cSettings: [
            .unsafeFlags(["-w"])
        ]
    ),

    // Box3d

    .target(
        name: "box3d",
        exclude: [
            ".github",
            "benchmark",
            "data",
            "docs",
            "extern",
            "samples",
            "shared",
            "test",
            "build.sh",
            "build_vs2026.bat",
            "CMakeLists.txt",
            "CMakePresets.json",
            "deploy_docs.sh",
            "LICENSE",
            "README.md"
        ],
        publicHeadersPath: "include",
        cSettings: [
            .unsafeFlags(["-w", "-std=c17"])
        ]
    ),

    // GLSLang & SPIRV

    .adaTarget(
        name: "SPIRVCompiler",
        dependencies: [
            "glslang"
        ],
        publicHeadersPath: ".",
        cxxSettings: [
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
        linkerSettings: [
            .linkedLibrary("m", .when(platforms: [.linux]))
        ]
    ),
    .target(
        name: "glslang",
        sources: {
            var glslangSources: [String] = [
                "glslang/MachineIndependent/attribute.cpp",
                "glslang/MachineIndependent/Constant.cpp",
                "glslang/MachineIndependent/glslang_tab.cpp",
                "glslang/MachineIndependent/InfoSink.cpp",
                "glslang/MachineIndependent/Initialize.cpp",
                "glslang/MachineIndependent/Intermediate.cpp",
                "glslang/MachineIndependent/intermOut.cpp",
                "glslang/MachineIndependent/IntermTraverse.cpp",
                "glslang/MachineIndependent/iomapper.cpp",
                "glslang/MachineIndependent/limits.cpp",
                "glslang/MachineIndependent/linkValidate.cpp",
                "glslang/MachineIndependent/parseConst.cpp",
                "glslang/MachineIndependent/ParseContextBase.cpp",
                "glslang/MachineIndependent/ParseHelper.cpp",
                "glslang/MachineIndependent/PoolAlloc.cpp",
                "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
                "glslang/MachineIndependent/preprocessor/PpContext.cpp",
                "glslang/MachineIndependent/preprocessor/Pp.cpp",
                "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
                "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
                "glslang/MachineIndependent/propagateNoContraction.cpp",
                "glslang/MachineIndependent/reflection.cpp",
                "glslang/MachineIndependent/RemoveTree.cpp",
                "glslang/MachineIndependent/Scan.cpp",
                "glslang/MachineIndependent/ShaderLang.cpp",
                "glslang/MachineIndependent/SpirvIntrinsics.cpp",
                "glslang/MachineIndependent/SymbolTable.cpp",
                "glslang/MachineIndependent/Versions.cpp",
                "glslang/GenericCodeGen/CodeGen.cpp",
                "glslang/GenericCodeGen/Link.cpp",
                "OGLCompilersDLL/InitializeDll.cpp",
                "SPIRV/disassemble.cpp",
                "SPIRV/doc.cpp",
                "SPIRV/GlslangToSpv.cpp",
                "SPIRV/InReadableOrder.cpp",
                "SPIRV/Logger.cpp",
                "SPIRV/SpvBuilder.cpp",
                "SPIRV/SpvPostProcess.cpp",
                "SPIRV/SPVRemapper.cpp",
                "SPIRV/SpvTools.cpp"
            ]

            #if os(Windows)
            glslangSources.append("glslang/OSDependent/Windows/ossource.cpp")
            #endif

            #if os(Linux) || os(android) || os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(WASI)
            glslangSources.append("glslang/OSDependent/Unix/ossource.cpp")
            #endif

            return glslangSources
        }(),
        publicHeadersPath: ".",
        cxxSettings: [
            .define("ENABLE_OPT", to: "0"),
            .define("_WASI_EMULATED_PROCESS_CLOCKS", .when(platforms: [.wasi])),
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
        linkerSettings: [
            .linkedLibrary("wasi-emulated-process-clocks", .when(platforms: [.wasi]))
        ]
    ),
    .target(
        name: "SPIRV-Cross",
        exclude: ["CMakeLists.txt",
                  "CODE_OF_CONDUCT.adoc",
                  "LICENSE",
                  "LICENSES",
                  "Makefile",
                  "README.md",
                  "appveyor.yml",
                  "build_glslang_spirv_tools.sh",
                  "checkout_glslang_spirv_tools.sh",
                  "format_all.sh",
                  "gn",
                  "pkg-config"
                 ],
        sources: ["spirv_cfg.cpp",
                  "spirv_cpp.cpp",
                  "spirv_cross.cpp",
                  "spirv_cross_c.cpp",
                  "spirv_cross_parsed_ir.cpp",
                  "spirv_cross_util.cpp",
                  "spirv_glsl.cpp",
                  "spirv_hlsl.cpp",
                  "spirv_msl.cpp",
                  "spirv_parser.cpp",
                  "spirv_reflect.cpp"],
        publicHeadersPath: "include",
        cxxSettings: [
            .define("SPIRV_CROSS_C_API_CPP", to: "1"),
            .define("SPIRV_CROSS_C_API_GLSL", to: "1"),
            .define("SPIRV_CROSS_C_API_HLSL", to: "1"),
            .define("SPIRV_CROSS_C_API_MSL", to: "1"),
            .define("SPIRV_CROSS_C_API_REFLECT", to: "1"),
            .define("SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS", .when(platforms: [.wasi])),
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ]
    ),

    // LibPNG

    .target(
        name: "libpng",
        dependencies: [
            .product(name: "ZLib", package: "zlib"),
        ],
        sources: [
            "libpng/png.c",
            "libpng/pngerror.c",
            "libpng/pngget.c",
            "libpng/pngmem.c",
            "libpng/pngpread.c",
            "libpng/pngread.c",
            "libpng/pngrio.c",
            "libpng/pngrtran.c",
            "libpng/pngrutil.c",
            "libpng/pngset.c",
            "libpng/pngtrans.c",
            "libpng/pngwio.c",
            "libpng/pngwrite.c",
            "libpng/pngwtran.c",
            "libpng/pngwutil.c",
        ],
        publicHeadersPath: "libpng/include",
        cSettings: [
            .define("PNG_ARM_NEON_OPT", to: "0"),
            .define("PNG_SETJMP_NOT_SUPPORTED", .when(platforms: [.wasi])),
            .unsafeFlags(["-mllvm", "-wasm-enable-sjlj"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
        linkerSettings: [
            .linkedLibrary("setjmp", .when(platforms: [.wasi]))
        ]
    ),
    .target(
        name: "miniaudio",
        sources: miniaudioSources,
        publicHeadersPath: "include",
        cSettings: [
            .define("MA_NO_DEVICE_IO", .when(platforms: [.wasi])),
            .define("MA_NO_THREADING", .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.iOS]))
        ]
    ),

    // MSDF

    .adaTarget(
        name: "AtlasFontGenerator",
        dependencies: [
            "MSDFAtlasGen",
            "HarfBuzz"
        ],
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("../harfbuzz"),
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ]
    ),
    .target(
        name: "AdaTextShaper",
        dependencies: [
            "HarfBuzz"
        ],
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("../harfbuzz"),
            .unsafeFlags(["-w"])
        ]
    ),
    .target(
        name: "HarfBuzz",
        path: "Sources/harfbuzz",
        sources: [
            "harfbuzz.cc"
        ],
        publicHeadersPath: ".",
        cxxSettings: [
            .headerSearchPath("."),
            .define("HB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR"),
            // The browser WASI profile uses a single-threaded event loop.
            .define("HB_NO_MT", .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ]
    ),
    .target(
        name: "MSDFGen",
        dependencies: [
            "freetype",
            "tinyxml"
        ],
        path: "Sources/msdf-atlas-gen/msdfgen",
        publicHeadersPath: ".",
        cxxSettings: [
            .define("MSDFGEN_USE_CPP11"),
            .headerSearchPath(".."),
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-mllvm", "-wasm-enable-sjlj"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
    ),
    .target(
        name: "MSDFAtlasGen",
        dependencies: [
            "MSDFGen"
        ],
        path: "Sources/msdf-atlas-gen/msdf-atlas-gen",
        publicHeadersPath: ".",
        cxxSettings: [
            .define("_CRT_SECURE_NO_WARNINGS"),
            .headerSearchPath(".."),
            .unsafeFlags(["-fno-exceptions"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
    ),
    .target(
        name: "freetype",
        path: "Sources/msdf-atlas-gen/freetype",
        sources: [
            "src/autofit/autofit.c",
            "src/base/ftbase.c",
            "src/base/ftbbox.c",
            "src/base/ftbdf.c",
            "src/base/ftbitmap.c",
            "src/base/ftcid.c",
            "src/base/ftdebug.c",
            "src/base/ftfstype.c",
            "src/base/ftgasp.c",
            "src/base/ftglyph.c",
            "src/base/ftgxval.c",
            "src/base/ftinit.c",
            "src/base/ftmm.c",
            "src/base/ftotval.c",
            "src/base/ftpatent.c",
            "src/base/ftpfr.c",
            "src/base/ftstroke.c",
            "src/base/ftsynth.c",
            "src/base/ftsystem.c",
            "src/base/fttype1.c",
            "src/base/ftwinfnt.c",
            "src/bdf/bdf.c",
            "src/bzip2/ftbzip2.c",
            "src/cache/ftcache.c",
            "src/cff/cff.c",
            "src/cid/type1cid.c",
            "src/gzip/ftgzip.c",
            "src/lzw/ftlzw.c",
            "src/pcf/pcf.c",
            "src/pfr/pfr.c",
            "src/psaux/psaux.c",
            "src/pshinter/pshinter.c",
            "src/psnames/psnames.c",
            "src/raster/raster.c",
            "src/sdf/sdf.c",
            "src/sfnt/sfnt.c",
            "src/smooth/smooth.c",
            "src/truetype/truetype.c",
            "src/type1/type1.c",
            "src/type42/type42.c",
            "src/winfonts/winfnt.c"
        ],
        publicHeadersPath: "include",
        cSettings: [
            .define("FT2_BUILD_LIBRARY"),
            .define("_CRT_SECURE_NO_WARNINGS"),
            .define("_CRT_NONSTDC_NO_WARNINGS"),
            .define("HAVE_UNISTD_H", to: "1", .when(platforms: [.wasi])),
            .unsafeFlags(["-mllvm", "-wasm-enable-sjlj"], .when(platforms: [.wasi])),
            .unsafeFlags(["-w"])
        ],
        linkerSettings: [
            .linkedLibrary("setjmp", .when(platforms: [.wasi]))
        ]
    ),
    .target(
        name: "tinyxml",
        path: "Sources/msdf-atlas-gen/tinyxml",
        publicHeadersPath: ".",
        cSettings: [
            .unsafeFlags(["-w"])
        ]
    )
]

// MARK: - Tests

targets += [
    .testTarget(
        name: "AdaEngineTests",
        dependencies: ["AdaEngine"],
    ),
    .testTarget(
        name: "MathTests",
        dependencies: [
            .product(name: "Numerics", package: "swift-numerics"),
            "Math"
        ],
    ),
    .testTarget(
        name: "AdaECSTests",
        dependencies: ["AdaECS", "Math"],
    ),
    .testTarget(
        name: "AdaMultiplayerTests",
        dependencies: ["AdaApp", "AdaECS", "AdaMultiplayer", "AdaTransform", "Math"],
    ),
    .testTarget(
        name: "AdaScriptingTests",
        dependencies: [
            "AdaScriptCompilerCore", "AdaScripting", "AdaApp", "AdaECS", "AdaInput", "AdaMultiplayer", "AdaRender", "AdaScene", "AdaSprite", "AdaTransform", "AdaUI", "Math",
            .product(name: "Yams", package: "Yams"),
        ],
    ),
    .testTarget(
        name: "AdaAssetsTests",
        dependencies: [
            "AdaAssets",
            "Math"
        ],
    ),
    .testTarget(
        name: "AdaAudioTests",
        dependencies: [
            "AdaAudio"
        ]
    ),
    .testTarget(
        name: "AdaTextTests",
        dependencies: [
            "AdaText"
        ]
    ),
    .testTarget(
        name: "AdaTransformTests",
        dependencies: [
            "AdaECS", 
            "AdaTransform",
            "Math"
        ],
    ),
    .testTarget(
        name: "AdaUITests",
        dependencies: [
            "AdaUI",
            "AdaPlatform",
            "AdaUtils",
            "AdaInput",
            "AdaRender",
            "AdaCorePipelines",
            "Math"
        ],
        resources: [
            .process("Resources")
        ],
    ),
    .testTarget(
        name: "AdaAnimationTests",
        dependencies: [
            "AdaAnimation",
            "Math"
        ]
    ),
    .testTarget(
        name: "AdaRenderTests",
        dependencies: [
            "AdaRender",
            "Math",
            "AdaUtilsTesting"
        ]
    ),
    .testTarget(
        name: "AdaInputTests",
        dependencies: [
            "AdaInput",
            "AdaUI",
            "Math"
        ],
    ),
    .testTarget(
        name: "AdaUtilsTests",
        dependencies: [
            "AdaUtils",
            "Math"
        ],
    ),
    .testTarget(
        name: "AdaSpriteTests",
        dependencies: [
            "AdaSprite",
            "Math"
        ]
    ),
    .testTarget(
        name: "AdaSceneTests",
        dependencies: [
            "AdaApp",
            "AdaScene",
            "AdaAnimation",
            "AdaECS",
            "AdaInput"
        ]
    )
]

#if os(macOS)
//targets.append(contentsOf: swiftLintTargets)
#endif

// MARK: - Package -

let package = Package(
    name: "AdaEngine",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2),
        .macOS(.v15),
    ],
    products: products,
    traits: [
        .trait(
            name: .wgpuTrait,
            description: "Enable WebGPU support"
        )
    ],
    dependencies: [],
    targets: targets,
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)

package.dependencies += [
    .package(
        url: "https://github.com/AdaEngine/gravity-lang.git",
        revision: "24695757a0ba5638b3633004a2166b7878c116de"
    ),
    .package(url: "https://github.com/apple/swift-collections", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.8.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-service-context", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-numerics", from: "1.1.1"),
    .package(url: "https://github.com/apple/swift-atomics", from: "1.3.0"),
    .package(url: "https://github.com/the-swift-collective/zlib.git", from: "1.3.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "0.2.1"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.3"),
    .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.36.0"),
    // TODO: SpectralDragon packages should move to AdaEngine
    .package(url: "https://github.com/SpectralDragon/Yams.git", revision: "fb676da"),
    // Plugins
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.5"),
    .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
]

if !isWebExportEnabled {
    package.dependencies.append(
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.62.1")
    )
}

if !isHeadlessCIEnabled {
    package.dependencies.append(
        .package(url: "https://github.com/adobe/swan", .upToNextMinor(from: "0.0.8"))
    )
}

private extension Target {
    /// Creates a regular target.
    ///
    /// A target can contain either Swift or C-family source files, but not both. It contains code that is built as
    /// a regular module for inclusion in a library or executable product, but that cannot itself be used as
    /// the main target of an executable product.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - dependencies: The dependencies of the target. A dependency can be another target in the package or a product from a package dependency.
    ///   - path: The custom path for the target. By default, the Swift Package Manager requires a target's sources to reside at predefined search paths;
    ///       for example, `[PackageRoot]/Sources/[TargetName]`.
    ///       Don't escape the package root; for example, values like `../Foo` or `/Foo` are invalid.
    ///   - exclude: A list of paths to files or directories that the Swift Package Manager shouldn't consider to be source or resource files.
    ///       A path is relative to the target's directory.
    ///       This parameter has precedence over the ``sources`` parameter.
    ///   - sources: An explicit list of source files. If you provide a path to a directory,
    ///       Swift Package Manager searches for valid source files recursively.
    ///   - resources: An explicit list of resources files.
    ///   - publicHeadersPath: The directory that contains public headers of a C-family library target.
    ///   - packageAccess: Allows package symbols from other targets in the package.
    ///   - cSettings: The C settings for this target.
    ///   - cxxSettings: The C++ settings for this target.
    ///   - swiftSettings: The Swift settings for this target.
    ///   - linkerSettings: The linker settings for this target.
    ///   - plugins: The plug-ins used by this target
    static func adaTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target {
        .target(
            name: name,
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ] + dependencies,
            path: path,
            exclude: exclude,
            sources: sources,
            resources: resources,
            publicHeadersPath: publicHeadersPath,
            packageAccess: packageAccess,
            cSettings: cSettings,
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings,
            plugins: plugins
        )
    }

    static func exampleTarget(
        name: String,
        path: String,
    ) -> Target {
        let sourcePath = "\(path)/\(name).swift"
        let excludedExampleSources = (
            try? FileManager.default
                .subpathsOfDirectory(atPath: "Demos")
                .filter { $0.hasSuffix(".swift") && $0 != sourcePath }
        ) ?? []

        return .executableTarget(
            name: name,
            dependencies: [
                "AdaEngine"
            ],
            path: "Demos",
            exclude: excludedExampleSources,
            sources: [
                sourcePath
            ],
            resources: [
                .copy("Resources")
            ],
            packageAccess: false,
            linkerSettings: wasmExecutableLinkerSettings
        )
    }
}

// MARK: - Examples

let examplesTargets: [Target] = [
    // MARK: 2d
    .exampleTarget(name: "BunniesStressExample", path: "2d"),
    .exampleTarget(name: "TransformEntChildrenExample", path: "2d"),
    .exampleTarget(name: "CustomMaterialExample", path: "2d"),
    .exampleTarget(name: "TransparencyExample", path: "2d"),
    .exampleTarget(name: "Lighting2DExample", path: "2d"),
    .exampleTarget(name: "ManySpritesExample", path: "2d"),
    .exampleTarget(name: "LargeBox2DBenchmarkExample", path: "2d"),
    .exampleTarget(name: "FrustumCullingExample", path: "2d"),
    .exampleTarget(name: "Gravity2DExample", path: "2d"),
    .exampleTarget(name: "ThrowingShapes2DExample", path: "2d"),
    .exampleTarget(name: "Text2dExample", path: "2d"),
    .exampleTarget(name: "SpriteExample", path: "2d"),
    .exampleTarget(name: "WGSLExample", path: "2d"),

    // MARK: Input
    .exampleTarget(name: "GamepadExample", path: "Input"),

    // MARK: Scene
    .exampleTarget(name: "LoadSceneExample", path: "Scene"),
    .exampleTarget(name: "LdtkTilemapExample", path: "Scene"),
    .exampleTarget(name: "CustomTileMapExample", path: "Scene"),
    .exampleTarget(name: "ScriptableComponentExample", path: "Scene"),

    // MARK: Games
    .exampleTarget(name: "BulletHellGameExample", path: "Games"),

    // MARK: UI
    .exampleTarget(name: "TextureMenuExample", path: "UI"),
    .exampleTarget(name: "UITestSceneExample", path: "UI"),
    .exampleTarget(name: "AnimatedTextRendererExample", path: "UI"),
    .exampleTarget(name: "ButtonExample", path: "UI"),
    .exampleTarget(name: "KanbanBoardExample", path: "UI"),
    .exampleTarget(name: "TextFieldExample", path: "UI"),
    .exampleTarget(name: "NativeViewExample", path: "UI"),
    .exampleTarget(name: "SceneViewExample", path: "UI"),
    .exampleTarget(name: "AdaptiveSceneViewExample", path: "UI"),

    // MARK: Example
    .exampleTarget(name: "SimpleCollideEventExample", path: "Events"),

    // MARK: 3D
    .exampleTarget(name: "Box3DPhysicsExample", path: "3d"),
    .exampleTarget(name: "PBRMaterialShowcaseExample", path: "3d"),
    .exampleTarget(name: "SimpleCubeExample", path: "3d"),
    .exampleTarget(name: "LargePyramidBenchmarkExample", path: "3d"),
]

package.targets.append(contentsOf: examplesTargets)

// MARK:  Examples -

// MARK: - Traits

var defaultTraits: Set<String> = []

if isWGPUEnabled {
    defaultTraits.insert(.wgpuTrait)
}

package.traits.insert(
    .default(enabledTraits: defaultTraits)
)
