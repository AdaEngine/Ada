@testable import AdaEditor
@testable import AdaScripting
@_spi(Internal) import AdaApp
@_spi(Internal) import AdaAssets
@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Testing

@Suite("Community native player", .serialized)
struct EditorCommunityNativeTests {
    private let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let release = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func files() -> [String: Data] {
        let project = """
        {"schemaVersion":3,"project":{"name":"UGCProbe"},"paths":{"sources":"Sources","assets":"Assets"},"build":{"system":"adascript"},"runtime":{"entry":{"startupSystem":"game.start"},"plugins":{"preset":"ui"}}}
        """
        return ["ada-game.json": Data("{\"formatVersion\":1,\"runtime\":\"adascript\",\"apiVersion\":1}".utf8), ".ada/project.json": Data(project.utf8),
                "Sources/Game.ada": Data("@system(scheduler: \"startup\", id: \"game.start\") class Game { func update(context) { var n = 0; while (n < 3) { n += 1; } } }".utf8)]
    }

    private func manifest(_ files: [String: Data]) -> EditorCommunityPackageManifest {
        .init(formatVersion: 1, runtime: "adascript", apiVersion: 1, files: files.sorted { $0.key < $1.key }.map {
            .init(path: $0.key, size: $0.value.count, sha256: EditorCommunityPackageManifest.digest($0.value))
        })
    }

    @Test func pathsVersionsAndNativeBinariesFailClosed() throws {
        try manifest(files()).validate()
        for path in ["../private", "/absolute", "Assets/a%2fb.png", "Assets/module.dylib", ".ada/libraries.lock.json", "Sources/main.swift", "Assets/a/../b.png"] {
            #expect(!EditorCommunityPackageManifest.validPath(path))
        }
        let invalid = EditorCommunityPackageManifest(formatVersion: 1, runtime: "adascript", apiVersion: 3, files: manifest(files()).files)
        #expect(throws: EditorCommunityPackageManifest.Failure.self) { try invalid.validate() }
    }

    @Test func scriptPolicyAndLoopInstrumentation() throws {
        for source in ["System.exit(0);", "var x = exit;", "extern var host;", "class __adaUGCBudget {}", "var x = \"\\(System.exit(0))\";"] {
            #expect(throws: AdaScriptCommunityLowerer.Failure.self) { try AdaScriptCommunityLowerer.validate(source: source) }
        }
        let source = "func run() { while (true) { var text = \"while for\"; } } // System.exit"
        try AdaScriptCommunityLowerer.validate(source: source)
        let guarded = try AdaScriptCommunityLowerer.instrument(source: source)
        #expect(guarded.components(separatedBy: "__adaUGCBudget.check()").count == 3)
        #expect(throws: AdaScriptCommunityLowerer.Failure.self) { try AdaScriptCommunityLowerer.instrument(source: "while (true) n += 1;") }
    }

    @Test func guardedIncludeContainsCheckpoints() throws {
        let module = try GravityScriptModuleResolver.resolve([.init(path: "Loop.ada", source: "@system class Loop { func update(context) { while (true) {} } }")])
        let source = try #require(module.sourcesByPath["Loop.ada"])
        let guarded = try AdaScriptCommunityLowerer.instrument(source: source.source)
        #expect(guarded.components(separatedBy: "__adaUGCBudget.check()").count == 3, Comment(rawValue: guarded))
    }

    @Test @MainActor func infiniteScriptReturnsWithDiagnostic() async throws {
        let plugin = try AdaScriptPlugin(sources: [.init(path: "Loop.ada", source: "@system(scheduler: \"startup\", id: \"loop\") class Loop { func update(context) { while (true) {} } }")], name: "CommunityLoop", communityPolicy: .init(maximumCheckpoints: 100))
        let app = AppWorlds(main: World(name: "CommunityLoop"))
        app.addPlugin(plugin)
        try await app.build()
        if plugin.diagnostics.isEmpty { await app.main.runScheduler(.startup) }
        #expect(plugin.diagnostics.contains { $0.contains("execution limit") })
    }

    @Test @MainActor func finiteScriptExecutesWithinBudget() async throws {
        let plugin = try AdaScriptPlugin(sources: [.init(path: "Finite.ada", source: "@system(scheduler: \"startup\") class Finite { func update(context) { var n = 0; while (n < 3) { n += 1; } assert(n == 3); } }")], name: "CommunityFinite", communityPolicy: .init(maximumCheckpoints: 100))
        let app = AppWorlds(main: World(name: "CommunityFinite"))
        app.addPlugin(plugin)
        try await app.build()
        await app.main.runScheduler(.startup)
        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
    }

    @Test func downloadIntegrityCacheAndReleasePinning() async throws {
        let original = files()
        let manifestData = try JSONEncoder().encode(manifest(original))
        let game = EditorCommunityGame(id: id, title: "Probe", description: "", tags: [], likes: 0, coverURL: nil, screenshotURLs: [], playURL: try #require(URL(string: "https://games.example.com/")), runtime: .adaScript(releaseID: release))
        let page: EditorCloudValue = ["id": .string(id), "title": "Probe", "published": true,
            "publication": ["mode": "ugc", "approved": true, "url": .string(game.playURL.absoluteString), "releaseId": .string(release), "uploadId": .string(release), "runtime": ["kind": "adascript", "apiVersion": 1, "manifestPath": "ada-manifest.json"]]]
        let pageData = try JSONEncoder().encode(page)
        let client = EditorCommunityClient(server: try #require(URL(string: "https://cloud.example.com"))) { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let data: Data
            if url.host == "cloud.example.com" { data = pageData }
            else {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "release", value: game.runtime.release)])
                data = url.lastPathComponent == "ada-manifest.json" ? manifestData : try #require(original[String(url.path.dropFirst())])
            }
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorCommunityPackageStore(root: root)
        let directory = try await store.load(game: game, client: client)
        #expect(try Data(contentsOf: directory.appendingPathComponent("Sources/Game.ada")) == original["Sources/Game.ada"])
        _ = try await store.load(game: game, client: client)
        let preview = EditorCommunityGame(id: id, title: "Preview", description: "", tags: [], likes: 0, coverURL: nil, screenshotURLs: [], playURL: try #require(URL(string: "https://another-origin.example.com/")), runtime: game.runtime, isPreview: true)
        let previewClient = EditorCommunityClient(server: client.server) { request in
            let url = try #require(request.url)
            let data = url.lastPathComponent == "ada-manifest.json" ? manifestData : try #require(original[String(url.path.dropFirst())])
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let previewDirectory = try await store.load(game: preview, client: previewClient)
        #expect(directory.deletingLastPathComponent().deletingLastPathComponent() != previewDirectory.deletingLastPathComponent().deletingLastPathComponent())
        let corrupt = EditorCommunityClient(server: client.server) { request in
            let url = try #require(request.url)
            let data = url.host == "cloud.example.com" ? pageData : url.lastPathComponent == "ada-manifest.json" ? manifestData : Data("corrupt".utf8)
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let emptyStore = EditorCommunityPackageStore(root: root.appendingPathComponent("other"))
        await #expect(throws: EditorCommunityPackageManifest.Failure.self) { try await emptyStore.load(game: game, client: corrupt) }
    }

    @Test @MainActor func packageCreatesRestrictedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, data) in files() {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: id)
        #expect(session.directories.restrictToVirtualRoots)
        #expect(session.script.diagnostics.isEmpty)
    }

    @Test @MainActor func assetRootsDenyNativePathsAndSymlinkEscapes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Assets")
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("escape"), withDestinationURL: outside)
        let scope = UUID()
        await AppWorldsExecutionContext.$currentID.withValue(scope) {
            await AssetsManager.setProjectDirectories(ProjectDirectories(source: root, assetsDirectory: resources, userDataDirectory: root.appendingPathComponent("Saves"), cacheDirectory: root.appendingPathComponent("Cache"), restrictToVirtualRoots: true))
            #expect(AssetsManager.resolveAssetURL(at: "@res://image.png") == resources.appendingPathComponent("image.png"))
            for path in [outside.path, "file://" + outside.path, "@res://../Outside/file", "@res://escape/file"] {
                #expect(AssetsManager.resolveAssetURL(at: path).lastPathComponent == ".denied")
            }
            await AssetsManager.destroyScope(scope)
            #expect(AssetsManager.resolveAssetURL(at: outside.path).lastPathComponent == ".denied")
            #expect(AssetsManager.resolveAssetURL(at: "@res://image.png").lastPathComponent == ".denied")
        }
    }

    @Test @MainActor func scenePackageUsesProductionPlayer() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Native scene test")))
        }
        EditorComponentRegistry.registerBuiltIns()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ada-native-scene-" + UUID().uuidString)
        var contents = files()
        var project = try JSONDecoder().decode(AdaProject.self, from: try #require(contents[".ada/project.json"]))
        project.runtime.entry.scene = "Assets/Main.ascn"
        project.runtime.plugins = .init(preset: .game2D)
        contents[".ada/project.json"] = try JSONEncoder().encode(project)
        var scene = EditorSceneModel(scene: .init(id: "native-scene", name: "Native World"), entities: [])
        _ = scene.addEntity(preset: .camera)
        let sprite = scene.addEntity(preset: .sprite)
        let index = try #require(scene.entities.firstIndex { $0.id == sprite.id })
        scene.entities[index].components[EditorBuiltInComponentType.sprite]?["size"] = .array([.double(120), .double(120)])
        scene.entities[index].components[EditorBuiltInComponentType.sprite]?["tintColor"] = .object(["red": .double(0.2), "green": .double(0.65), "blue": .double(1), "alpha": .double(1)])
        contents["Assets/Main.ascn"] = Data(try scene.encodedYAML().utf8)
        for (path, data) in contents {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: id)
        #expect(session.artifact.sceneModel?.entities.count == 2)
        #expect(session.script.diagnostics.isEmpty)
        // Retain the test-owned project for native Simulator QA; no fixture hook enters the app.
        try root.path.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ada-native-scene-path.txt"), atomically: true, encoding: .utf8)
    }
}

private extension EditorCommunityGame.Runtime {
    var release: String? { if case .adaScript(let id) = self { id } else { nil } }
}
