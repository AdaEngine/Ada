#if os(macOS) && canImport(GravityAOT)
import AdaEngine
import AdaScriptCompilerCore
import CGravity
import Darwin
import Foundation
import GravityAOT

struct EditorAdaScriptNativeExportOptions: Sendable {
    enum Destination: String, Sendable { case macOS, web }
    enum Configuration: String, Sendable { case debug, release }
    let destination: Destination
    let gravityRoot: URL
    let engineRoot: URL
    let swiftExecutable: String
    var swiftSDK = "swift-6.3.2-RELEASE_wasm"
    var buildsPlayer = true
    var configuration: Configuration = .release
    var scratchDirectory: URL?
    var hostScratchDirectory: URL?
}

/// Each export is prepared in an unpublished directory. The old export remains
/// available until compilation, resource staging and platform packaging succeed.
actor EditorAdaScriptNativeExporter {
    private let runner: any EditorProcessRunning
    init(runner: any EditorProcessRunning = EditorProcessRunner()) { self.runner = runner }

    func export(
        project: AdaProject,
        at root: URL,
        to output: URL,
        options: EditorAdaScriptNativeExportOptions,
        log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void = { _ in }
    ) async throws -> URL {
        try EditorDistribution.current.validate(buildSystem: .swiftpm)
        guard project.build.system.isAdaScript else { throw EditorPreviewBuildFailure(message: "Native export requires an AdaScript project.") }
        guard project.runtime.entry.view == nil else { throw EditorAdaScriptProjectBuildError.uiViewsUnavailable }
        let root = root.resolvingSymlinksInPath()
        let output = output.standardizedFileURL
        guard output != root, !root.path.hasPrefix(output.path + "/"), output.lastPathComponent != ".ada" else {
            throw EditorPreviewBuildFailure(message: "Export output must be a separate directory.")
        }
        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".ada-aot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let catalog = try EditorScriptableObjectCatalogLoader.load(project: project, at: root)
        let sources = catalog.playRuntime.sources
        guard !sources.isEmpty else { throw EditorAdaScriptProjectBuildError.noSources(path: project.paths.sources ?? "Sources") }
        // The analyzer and Gravity compiler both run before publishing any output.
        var environment = AdaScriptTypeEnvironment.standard
        environment.register(schemas: try AdaScriptSchemaParser.parse(sources: sources))
        try AdaScriptAnalyzer.analyze(sources: sources, environment: environment).requireValidTypes(mode: project.build.adaScriptTypeChecking)
        let constructors = await MainActor.run {
            EditorComponentRegistry.registerBuiltIns()
            return Dictionary(uniqueKeysWithValues: RuntimeTypeRegistry.registeredRuntimeComponentConstructors().map { ($0.name, $0.parameters.map(\.name)) })
        }
        let nativeSources = try AdaScriptNativeSourceBuilder.prepare(sources: sources, constructors: constructors)
        let sourceDirectory = stage.appendingPathComponent("AdaScriptSources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        var inputPaths: [String] = []
        for (index, source) in nativeSources.enumerated() {
            let url = sourceDirectory.appendingPathComponent("\(index)-\(URL(fileURLWithPath: source.path).lastPathComponent)")
            try source.source.write(to: url, atomically: true, encoding: .utf8)
            inputPaths.append(url.path)
        }
        let native = stage.appendingPathComponent("Sources/GameplayNative", isDirectory: true)
        let archive = native.appendingPathComponent("libada_game.a")
        if !FileManager.default.isExecutableFile(atPath: options.gravityRoot.appendingPathComponent("gravity").path) {
            try await run("/usr/bin/make", ["-j4"], at: options.gravityRoot, log: log)
        }
        let tool = options.gravityRoot.appendingPathComponent("tools/aot_build.py")
        guard FileManager.default.fileExists(atPath: tool.path) else { throw EditorPreviewBuildFailure(message: "The Gravity checkout does not contain tools/aot_build.py.") }
        try await run("/usr/bin/python3", [tool.path] + inputPaths + ["--module", "ada_game", "--output", archive.path], at: stage, log: log)
        let inspection = stage.appendingPathComponent("libada_game-inspection.dylib")
        try await run("/usr/bin/clang", ["-std=c11", "-dynamiclib", native.appendingPathComponent("ada_game.c").path, "-I", native.path, "-o", inspection.path], at: stage, log: log)
        try await Self.validateMetadata(at: inspection, project: project, sources: sources)
        try FileManager.default.removeItem(at: inspection)
        let include = native.appendingPathComponent("include", isDirectory: true)
        try FileManager.default.createDirectory(at: include, withIntermediateDirectories: true)
        try "#include <shared/gravity_aot_runtime.h>\nconst gravity_aot_module *ada_game_get_module(void);\n".write(
            to: include.appendingPathComponent("GameplayNative.h"),
            atomically: true,
            encoding: .utf8
        )
        let player = stage.appendingPathComponent("Sources/AdaNativeGame", isDirectory: true)
        try FileManager.default.createDirectory(at: player, withIntermediateDirectories: true)
        let assets = player.appendingPathComponent("GameAssets", isDirectory: true)
        let originalAssets = root.appendingPathComponent(project.paths.assets ?? "Assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: originalAssets.path) {
            try FileManager.default.copyItem(at: originalAssets, to: assets)
        } else {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        }
        try await Self.convertScenes(at: assets, originalRoot: originalAssets, sources: sources)
        try JSONEncoder().encode(project.inputActions).write(to: assets.appendingPathComponent("input-actions.json"))
        try JSONEncoder().encode(project).write(to: stage.appendingPathComponent("project.json"))
        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
        try Self.manifest(options: options).write(to: stage.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.player(project: project, sources: sources, plugins: plugins).write(to: player.appendingPathComponent("Game.swift"), atomically: true, encoding: .utf8)
        let scriptDirectory = stage.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        let script = scriptDirectory.appendingPathComponent("build_and_run.sh")
        try Self.buildRunScript(options: options).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let codexDirectory = stage.appendingPathComponent(".codex/environments")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        # THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
        version = 1
        name = "AdaNativeGame"
        [setup]
        script = ""
        [[actions]]
        name = "Run"
        icon = "run"
        command = "./script/build_and_run.sh"
        """.write(to: codexDirectory.appendingPathComponent("environment.toml"), atomically: true, encoding: .utf8)
        let env = ["ADAENGINE_GRAVITY_PACKAGE_PATH": options.gravityRoot.path, "ADAENGINE_DISABLE_SWAN": "1"]
        if !options.buildsPlayer {
            // Package-only mode is used for reusable library exports and compiler QA.
        } else if options.destination == .macOS {
            let scratch = options.scratchDirectory ?? stage.appendingPathComponent("build-native")
            try await run(
                options.swiftExecutable,
                ["build", "--product", "AdaNativeGame", "-c", options.configuration.rawValue, "--scratch-path", scratch.path, "--jobs", "4"],
                at: stage,
                environment: env,
                log: log
            )
            let result = await runner.run(
                EditorProcessCommand(
                    executablePath: options.swiftExecutable,
                    arguments: ["build", "-c", options.configuration.rawValue, "--scratch-path", scratch.path, "--show-bin-path"],
                    workingDirectory: stage,
                    environment: env
                )
            )
            guard result.succeeded, let path = result.standardOutput.split(separator: "\n").last else { throw EditorPreviewBuildFailure(message: result.combinedOutput) }
            try Self.packageApp(
                binaryDirectory: URL(fileURLWithPath: String(path)),
                to: stage.appendingPathComponent("AdaNativeGame.app"),
                title: project.project.displayName ?? project.project.name ?? "AdaScript Game"
            )
        } else {
            var webEnv = env
            webEnv["ADAENGINE_DISABLE_SWAN"] = "0"
            webEnv["ADAENGINE_WEB_EXPORT"] = "1"
            webEnv["BUILD_WASM"] = "1"
            webEnv["PATH"] = URL(fileURLWithPath: options.swiftExecutable).deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            var arguments = ["package", "--disable-sandbox"]
            if let hostScratch = options.hostScratchDirectory { arguments += ["--scratch-path", hostScratch.path] }
            arguments += ["--allow-writing-to-package-directory", "--allow-network-connections", "all", "export-web", "--product", "AdaNativeGame", "--output", stage.appendingPathComponent("web").path]
            if let wasmScratch = options.scratchDirectory { arguments += ["--scratch-path", wasmScratch.path] }
            arguments += ["--swift-sdk", options.swiftSDK]
            arguments += [options.configuration == .debug ? "--debug" : "--release"]
            try await run(options.swiftExecutable, arguments, at: stage, environment: webEnv, log: log)
        }
        try Data("{\"version\":1,\"destination\":\"\(options.destination.rawValue)\"}".utf8).write(to: stage.appendingPathComponent("ada-native-export.json"))
        try Task.checkCancellation()
        // Build paths are absolute in Bundle.module: ship a relative resource
        // fallback in the player and preserve the generated package for rebuilding.
        let backup = parent.appendingPathComponent(".ada-aot-backup-\(UUID().uuidString)")
        let existed = FileManager.default.fileExists(atPath: output.path)
        if existed {
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("ada-native-export.json").path) else {
                throw EditorPreviewBuildFailure(message: "Output already exists and is not an AdaScript native export: \(output.path)")
            }
            try FileManager.default.moveItem(at: output, to: backup)
        }
        do { try FileManager.default.moveItem(at: stage, to: output) } catch {
            if existed { try? FileManager.default.moveItem(at: backup, to: output) }
            throw error
        }
        if existed { try? FileManager.default.removeItem(at: backup) }
        return output
    }

    @MainActor
    private static func validateMetadata(at url: URL, project: AdaProject, sources: [AdaScriptSource]) throws {
        let library = try NativeExportLibrary(url: url)
        let module = unsafe try NativeModule(module: library.module(), retaining: library)
        let plugin = try AdaScriptNativePlugin(module: module, name: project.runtime.moduleName, sources: sources, startupSystemIdentifier: project.runtime.entry.startupSystem)
        try plugin.validateBindings()
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        at directory: URL,
        environment: [String: String] = [:],
        log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let result = await runner.run(EditorProcessCommand(executablePath: executable, arguments: arguments, workingDirectory: directory, environment: environment), output: log)
        try Task.checkCancellation()
        guard result.succeeded else { throw EditorPreviewBuildFailure(message: result.combinedOutput) }
    }

    @MainActor
    private static func convertScenes(at assets: URL, originalRoot: URL, sources: [AdaScriptSource]) throws {
        EditorComponentRegistry.registerBuiltIns()
        let schemas = try AdaScriptSchemaParser.parse(sources: sources).filter { $0.kind == .component }
        let nativeNames = Set(schemas.flatMap { [$0.name, $0.id] })
        guard let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in files where url.pathExtension == "ascn" {
            let model = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
            let animations = Dictionary(grouping: model.animations ?? [], by: \.targetEntityID)
            guard Set(animations.keys).isSubset(of: Set(model.entities.map(\.id))) else {
                throw EditorPreviewBuildFailure(message: "Animation references a missing scene entity in \(url.lastPathComponent).")
            }
            let originalSceneURL = originalRoot.appendingPathComponent(String(url.path.dropFirst(assets.path.count + 1)))
            let items = try model.entities.map { item in
                var values: [String: Data] = [:]
                for (name, originalPayload) in item.components {
                    let payload = try EditorSceneFileLoader.resolvedComponentPayload(typeName: name, payload: originalPayload, sourceURL: originalSceneURL, resourceRootURL: originalRoot)
                    if nativeNames.contains(name) || name == String(reflecting: ScriptableComponents.self) {
                        values[name] = try JSONSerialization.data(withJSONObject: payload.mapValues(\.jsonCompatibleValue))
                    } else if name == String(reflecting: Camera.self), let camera = try EditorComponentRegistry.decode(typeName: name, payload: payload) as? Camera {
                        values[name] = try JSONEncoder().encode(SceneCameraSettings(camera: camera))
                    } else if name == String(reflecting: TileMapComponent.self) {
                        let reference: String
                        if let path = originalPayload["map"]?.stringValue, !path.isEmpty {
                            if path.hasPrefix("@res://") { reference = path } else {
                                let url = URL(fileURLWithPath: path, relativeTo: originalSceneURL.deletingLastPathComponent()).standardizedFileURL
                                guard url.path.hasPrefix(originalRoot.path + "/") else { throw EditorPreviewBuildFailure(message: "Tile map is outside project assets.") }
                                reference = "@res://" + String(url.path.dropFirst(originalRoot.path.count + 1))
                            }
                        } else {
                            let inline = assets.appendingPathComponent("NativeInlineMaps")
                            try FileManager.default.createDirectory(at: inline, withIntermediateDirectories: true)
                            let file = inline.appendingPathComponent("\(UUID().uuidString).tilemap")
                            let content = detachReferences(payload.mapValues(\.jsonCompatibleValue), originalRoot: originalRoot)
                            try JSONSerialization.data(withJSONObject: content).write(to: file)
                            reference = "@res://NativeInlineMaps/" + file.lastPathComponent
                        }
                        let size = originalPayload["tileDisplaySize"]?.vector2Value
                        values[name] = try JSONEncoder().encode(AdaScriptNativeTileMapReference(path: reference, width: size?.x ?? 16, height: size?.y ?? 16))
                    } else if payload.isEmpty, RuntimeTypeRegistry.makeDefaultComponent(named: name) != nil {
                        values[name] = Data("{}".utf8)
                    } else {
                        guard let value = try EditorComponentRegistry.decode(typeName: name, payload: payload) as? any Encodable else {
                            throw EditorPreviewBuildFailure(message: "Native export cannot encode component '\(name)' in \(url.lastPathComponent).")
                        }
                        values[name] = try JSONEncoder().encode(value)
                    }
                    // Detach resource references from the developer's absolute paths.
                    if let data = values[name] {
                        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                        values[name] = try JSONSerialization.data(withJSONObject: detachReferences(json, originalRoot: originalRoot), options: [.fragmentsAllowed])
                    }
                }
                let entityClips = animations[item.id] ?? []
                guard Set(entityClips.map(\.name)).count == entityClips.count else {
                    throw EditorPreviewBuildFailure(message: "Duplicate animation clip name on '\(item.id)'.")
                }
                let clips = try entityClips.map { clip in
                    guard !clip.name.isEmpty, clip.duration.isFinite, clip.duration > 0,
                        clip.tracks.allSatisfy({ track in track.keyframes.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.value.isFinite } })
                    else { throw EditorPreviewBuildFailure(message: "Invalid animation clip '\(clip.name)'.") }
                    guard let payload = item.components[String(reflecting: Transform.self)],
                          let transform = try EditorComponentRegistry.decode(typeName: String(reflecting: Transform.self), payload: payload) as? Transform else {
                        throw EditorPreviewBuildFailure(message: "Animation target '\(item.id)' requires Transform.")
                    }
                    return try clip.makeSerializableClip(initialTransform: transform).encodeToJSONData()
                }
                return AdaScriptNativeSceneDocument.Item(id: item.id, name: item.name, enabled: item.enabled, parent: item.parent, components: values, animationClips: clips)
            }
            try JSONEncoder().encode(AdaScriptNativeSceneDocument(name: model.scene.name, entities: items)).write(to: url, options: .atomic)
        }
    }

    private static func detachReferences(_ value: Any, originalRoot: URL) -> Any {
        if let string = value as? String, string.hasPrefix(originalRoot.path + "/") {
            return "@res://" + String(string.dropFirst(originalRoot.path.count + 1))
        }
        if let values = value as? [Any] { return values.map { detachReferences($0, originalRoot: originalRoot) } }
        if let values = value as? [String: Any] { return values.mapValues { detachReferences($0, originalRoot: originalRoot) } }
        return value
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 34: "\\\""
            case 92: "\\\\"
            case 10: "\\n"
            case 13: "\\r"
            case 9: "\\t"
            case 0...31: "\\u{\(String(scalar.value, radix: 16))}"
            default: String(scalar)
            }
        }.joined()
        return "\"" + escaped + "\""
    }

    private static func manifest(options: EditorAdaScriptNativeExportOptions) -> String {
        """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "AdaNativeGame", platforms: [.macOS(.v15)], products: [.executable(name: "AdaNativeGame", targets: ["AdaNativeGame"])], dependencies: [
            .package(name: "AdaEngine", path: \(quote(options.engineRoot.path))),
            .package(name: "gravity-lang", path: \(quote(options.gravityRoot.path))),
            .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.53.0")
        ], targets: [
            .target(name: "GameplayNative", dependencies: [.product(name: "CGravity", package: "gravity-lang")], exclude: ["libada_game.a", "ada_game.h", "ada_game.sources.json"], publicHeadersPath: "include"),
            .executableTarget(name: "AdaNativeGame", dependencies: ["GameplayNative", .product(name: "AdaEngine", package: "AdaEngine"), .product(name: "AdaMultiplayer", package: "AdaEngine"), .product(name: "GravityAOT", package: "gravity-lang"), .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi]))], resources: [.copy("GameAssets")], linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "--export-if-defined=main", "-Xlinker", "--export-if-defined=__main_argc_argv"], .when(platforms: [.wasi])), .unsafeFlags(["-Xlinker", "--strip-debug"], .when(platforms: [.wasi], configuration: .release))])
        ])
        """
    }

    private static func player(project: AdaProject, sources: [AdaScriptSource], plugins: EditorAdaScriptResolvedRuntimePlugins) -> String {
        let entryScene = project.runtime.entry.scene ?? ""
        let assetsPrefix = (project.paths.assets ?? "Assets") + "/"
        // Project metadata uses project-relative paths; the standalone player starts at GameAssets.
        let scene = entryScene.hasPrefix(assetsPrefix) ? String(entryScene.dropFirst(assetsPrefix.count)) : entryScene
        let title = project.runtime.window.title ?? project.project.displayName ?? project.project.name ?? "AdaScript Game"
        let metadata = sources.map { "AdaScriptSource(path: \(quote($0.path)), source: \(quote($0.source)))" }.joined(separator: ",\n")
        let pluginCode = plugins.pluginIDs.compactMap { id -> String? in
            switch id {
            case .core2D: "app.addPlugin(Core2DPlugin())"
            case .core3D: "app.addPlugin(Core3DPlugin())"
            case .light2D: "app.addPlugin(Light2DPlugin())"
            case .mesh2D: "app.addPlugin(Mesh2DPlugin())"
            case .sprite: "app.addPlugin(SpritePlugin())"
            case .upscale: "app.addPlugin(UpscalePlugin())"
            case .audio: "app.addPlugin(AudioPlugin())"
            case .tilemap: "app.addPlugin(TileMapPlugin())"
            case .physics2D: "app.addPlugin(Physics2DPlugin(gravity: [\(plugins.physics2DGravity[0]), \(plugins.physics2DGravity[1])]))"
            case .physics3D: "app.addPlugin(Physics3DPlugin())"
            case .model3D: nil
            case .multiplayer: "app.addPlugin(NativeGameNetwork())"
            default: nil
            }
        }.joined(separator: "\n")
        return """
            import AdaEngine
            import AdaMultiplayer
            import GravityAOT
            import GameplayNative
            #if os(WASI)
            import JavaScriptKit
            #endif
            @main struct AdaNativeGame: App {
                var body: some AppScene {
                WindowGroup(content: { GameView() }, assetBundle: Bundle.module)
                    .windowTitle(\(quote(title)))
                    .windowMode(.windowed)
                    .minimumSize(width: \(project.runtime.window.size.width), height: \(project.runtime.window.size.height))
                    .windowResizable(\(project.runtime.window.isResizable))
            }
            }
            @MainActor private struct GameView: View {
                var body: some View { SceneView(make: { app in
                    do {
                        let base = Bundle.main.bundleURL
                        let candidates = ["AdaNativeGame_AdaNativeGame.bundle", "AdaNativeGame_AdaNativeGame.resources"].map { base.appendingPathComponent($0 + "/GameAssets") }
                        guard let assetURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? Bundle.module.resourceURL?.appendingPathComponent("GameAssets") else {
                            throw AdaScriptError.invalidManifest("Native game assets are missing")
                        }
                        let assets = assetURL.resolvingSymlinksInPath().standardizedFileURL
                        let actions = try JSONDecoder().decode([InputAction].self, from: Data(contentsOf: assets.appendingPathComponent("input-actions.json")))
                        app.addPlugin(TransformPlugin()).addPlugin(InputPlugin(actions: actions)).addPlugin(RenderWorldPlugin()).addPlugin(EventsPlugin()).addPlugin(CameraPlugin())
                        app.addPlugin(AssetsPlugin(assetDirectory: assets)).addPlugin(VisibilityPlugin()).addPlugin(TextPlugin()).addPlugin(ScenePlugin(includesModel3D: \(plugins.contains(.model3D)))).addPlugin(ScriptableObjectPlugin())
                        \(pluginCode)
                        guard let pointer = ada_game_get_module() else { throw NativeRuntimeError.malformedMetadata("Missing native gameplay module") }
                        let module = unsafe try NativeModule(module: pointer)
                        let plugin = try AdaScriptNativePlugin(module: module, name: \(quote(project.runtime.moduleName)), sources: [\(metadata)], startupSystemIdentifier: \(project.runtime.entry.startupSystem.map(quote) ?? "nil"), preloadedAssets: Self.preloadedAssetPaths(assets))
                        app.addPlugin(plugin)
                        app.addPlugin(NativeGameEntry(plugin: plugin, assets: assets))
                        NativeGameLog.write("[AdaScript AOT] Native module linked")
                    } catch { NativeGameLog.write("[AdaScript AOT] Startup failed: \\(error)") }
                }, updateContent: { _, _ in }) }
                private static func preloadedAssetPaths(_ assets: URL) -> [String] {
                    guard let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey]) else {
                        return []
                    }
                    return files.compactMap { entry in
                        guard let url = entry as? URL, url.pathExtension != "ascn", (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                            return nil
                        }
                        return "@res://" + String(url.path.dropFirst(assets.path.count + 1))
                    }
                }
            }
            private enum NativeGameLog {
            static func write(_ message: String) { FileHandle.standardOutput.write(Data((message + "\\n").utf8)) }
        }
        private struct NativeGameNetwork: Plugin {
                @MainActor func setup(in app: borrowing AppWorlds) {
                    let compatibility = NetworkCompatibility(gameIdentifier: \(quote(plugins.multiplayer.gameIdentifier)), buildIdentifier: \(quote(plugins.multiplayer.buildIdentifier)))
                    #if os(WASI)
                    struct Session: Decodable {
                        let sessionID: UUID; let peerID: UUID; let role: NetworkRole
                        let relayURL: URL; let connectionTicket: String
                    }
                    do {
                        if let json = JSObject.global["__adaMultiplayerSession"].string {
                            let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
                            let config = MultiplayerConfiguration(role: session.role, sessionID: SessionID(rawValue: session.sessionID), localPeerID: PeerID(rawValue: session.peerID), compatibility: compatibility)
                            MultiplayerPlugin(configuration: config, transport: CloudWebSocketTransport(credentials: CloudRelayCredentials(url: session.relayURL, connectionTicket: session.connectionTicket))).setup(in: app)
                        } else {
                            MultiplayerPlugin(configuration: MultiplayerConfiguration(role: .host, compatibility: compatibility), transport: InMemoryTransport(hub: InMemoryTransportHub())).setup(in: app)
                        }
                    } catch { NativeGameLog.write("[AdaScript AOT] Multiplayer startup failed: \\(error)") }
                    #else
                    let role: NetworkRole = \(quote(plugins.multiplayer.role)) == "peer" ? .peer : .host
                    let sessionID = SessionID(rawValue: UUID(uuid: (0x4d, 0x45, 0x44, 0x49, 0x45, 0x56, 0x41, 0x4c, 0x80, 0, 0, 0, 0, 0, 0, 1)))
                    let config = MultiplayerConfiguration(role: role, sessionID: sessionID, compatibility: compatibility)
                    MultiplayerPlugin(configuration: config, transport: LocalTCPTransport(host: \(quote(plugins.multiplayer.host)), port: \(plugins.multiplayer.port))).setup(in: app)
                    #endif
                }
            }
            private struct NativeGameEntry: Plugin {
                let plugin: AdaScriptNativePlugin
                let assets: URL
                @MainActor func setup(in app: borrowing AppWorlds) {
                    do {
                        guard plugin.diagnostics.isEmpty else { throw AdaScriptError.invalidManifest(plugin.diagnostics.joined(separator: "\\n")) }
                        if !\(quote(scene)).isEmpty, let navigator = app.main.getResource(SceneNavigator.self) {
                            let load: @MainActor @Sendable (String) throws -> Scene = { path in
                                let relative = path.hasPrefix("@res://") ? String(path.dropFirst(7)) : path
                                let url = assets.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
                                guard url.path.hasPrefix(assets.path + "/") else { throw AdaScriptError.invalidManifest("Scene path is outside assets") }
                                let document = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: Data(contentsOf: url))
                                return try document.makeScene(components: plugin.componentDescriptors, resourceRoot: assets, sourceURL: url, tileMaps: plugin.preloadedTileMaps)
                            }
                            navigator.setSceneLoader { path in try await load(path) }
                            navigator.installInitialScene(try load(\(quote(scene))), make: { try load(\(quote(scene))) })
                        }
                        NativeGameLog.write("[AdaScript AOT] Native game ready")
                    } catch { NativeGameLog.write("[AdaScript AOT] Startup failed: \\(error)") }
                }
            }
        """
    }

    private static func buildRunScript(options: EditorAdaScriptNativeExportOptions) -> String {
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        return """
        #!/usr/bin/env bash
        set -euo pipefail
        MODE="${1:-run}"
        ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
        cd "$ROOT_DIR"
        SWIFT=\(shellQuote(options.swiftExecutable))
        export ADAENGINE_GRAVITY_PACKAGE_PATH=\(shellQuote(options.gravityRoot.path))
        export ADAENGINE_DISABLE_SWAN=1
        BUILD_DIR="${ADA_NATIVE_SCRATCH_PATH:-$ROOT_DIR/build-native}"
        APP_BUNDLE="$ROOT_DIR/AdaNativeGame.app"
        APP_BINARY="$APP_BUNDLE/Contents/MacOS/AdaNativeGame"
        for pid in $(pgrep -x AdaNativeGame || true); do
            command="$(ps -p "$pid" -o command= || true)"
            if [[ "$command" == "$APP_BINARY" || "$command" == "$APP_BINARY "* ]]; then kill "$pid"; fi
        done
        "$SWIFT" build --product AdaNativeGame -c \(options.configuration.rawValue) --scratch-path "$BUILD_DIR" --jobs 4
        BIN_DIR="$("$SWIFT" build -c \(options.configuration.rawValue) --scratch-path "$BUILD_DIR" --show-bin-path)"
        mkdir -p "$APP_BUNDLE/Contents/MacOS"
        cp "$BIN_DIR/AdaNativeGame" "$APP_BINARY"
        for resource in "$BIN_DIR"/*.bundle "$BIN_DIR"/*.resources; do
            [[ -e "$resource" ]] || continue
            name="$(basename "$resource")"
            rm -rf "$APP_BUNDLE/$name"
            cp -R "$resource" "$APP_BUNDLE/$name"
        done
        [[ -f "$APP_BUNDLE/Contents/Info.plist" ]] || { echo "Export the macOS player before running this script." >&2; exit 1; }
        case "$MODE" in
            run) /usr/bin/open -n "$APP_BUNDLE" ;;
            --debug|debug) lldb -- "$APP_BINARY" ;;
            --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "AdaNativeGame"' ;;
            --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "org.adaengine.nativegame"' ;;
            --verify|verify) /usr/bin/open -n "$APP_BUNDLE" --stdout /tmp/ada-native-game-launch.log --stderr /tmp/ada-native-game-launch.log; sleep 2; pgrep -x AdaNativeGame >/dev/null ;;
            *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
        esac
        """
    }

    private static func packageApp(binaryDirectory: URL, to bundle: URL, title: String) throws {
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binaryDirectory.appendingPathComponent("AdaNativeGame"), to: macOS.appendingPathComponent("AdaNativeGame"))
        for url in try FileManager.default.contentsOfDirectory(at: binaryDirectory, includingPropertiesForKeys: nil) where url.pathExtension == "bundle" || url.pathExtension == "resources" {
            try FileManager.default.copyItem(at: url, to: bundle.appendingPathComponent(url.lastPathComponent))
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": "AdaNativeGame", "CFBundleIdentifier": "org.adaengine.nativegame", "CFBundleName": title, "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "15.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }
}
/// Immutable loader ownership is retained by NativeModule for all metadata reads.
private final class NativeExportLibrary {
    private let handle: UnsafeMutableRawPointer
    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw EditorPreviewBuildFailure(message: "Could not load the generated AdaScript module for metadata validation.") }
        self.handle = handle
    }
    deinit { dlclose(handle) }
    func module() throws -> UnsafePointer<gravity_aot_module> {
        guard let symbol = dlsym(handle, "ada_game_get_module") else { throw EditorPreviewBuildFailure(message: "Generated module accessor is missing.") }
        let get = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafePointer<gravity_aot_module>?).self)
        guard let module = get() else { throw EditorPreviewBuildFailure(message: "Generated module metadata is missing.") }
        return module
    }
}
#endif
