import AdaScriptCompilerCore
import Foundation
import Testing

@Suite("Web Player portable bundle")
struct AdaWebPlayerTests {
    @Test("Converts Medieval Arena portable project to scene profile")
    func medievalArenaProject() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Demos/MedievalArena", isDirectory: true)
        let project = try AdaWebPlayerProject.load(at: directory)

        #expect(project.profile == "scene")
        #expect(project.runtimeAPI == 3)
        #expect(project.sources.count == 4)
        #expect(project.files?.contains("Assets/Scenes/Main.ascn") == true)
        #expect(project.files?.contains("Assets/Maps/Arena.tilemap") == true)
        #expect(try project.loadSources(at: directory).count == 4)
    }

    @Test("External source edits are picked up without changing the player bytes")
    func externalSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let template = root.appendingPathComponent("template")
        try makeProject(at: project)
        try makeTemplate(at: template)
        let first = root.appendingPathComponent("first")
        try AdaWebPlayerBundle.assemble(template: template, project: project, output: first)
        try source("Second").write(to: project.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        let second = root.appendingPathComponent("second")
        try AdaWebPlayerBundle.assemble(template: template, project: project, output: second)
        #expect(try Data(contentsOf: first.appendingPathComponent("AdaWebPlayer.wasm")) == Data(contentsOf: second.appendingPathComponent("AdaWebPlayer.wasm")))
        let manifest = try AdaWebPlayerProject.load(at: second.appendingPathComponent("game"))
        #expect(try manifest.loadSources(at: second.appendingPathComponent("game")).first?.source == source("Second"))
        let resources = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: second.appendingPathComponent("ada-resource-manifest.json")))
        #expect(resources.contains(Entry(path: "game/project.json", url: "game/project.json")))
        #expect(resources.contains(Entry(path: "game/Sources/Main.ada", url: "game/Sources/Main.ada")))
        #expect(!FileManager.default.fileExists(atPath: template.appendingPathComponent("game").path))
        #expect(throws: AdaWebPlayerProjectError.self) {
            try AdaWebPlayerBundle.assemble(template: template, project: project, output: first)
        }
    }

    @Test("Rejects incompatible APIs, duplicate paths and escaping sources", arguments: ["../Main.ada", "/Main.ada", "Sources/../Main.ada", "Main\\Other.ada"])
    func invalidPaths(_ path: String) {
        #expect(throws: AdaWebPlayerProjectError.self) {
            try AdaWebPlayerProject(title: "Game", entryView: "Game", sources: [path]).validate()
        }
    }

    @Test("Checks runtime API and case-insensitive collisions")
    func incompatibleProject() {
        var project = AdaWebPlayerProject(title: "Game", entryView: "Game", sources: ["Main.ada"])
        project.runtimeAPI = 4
        #expect(throws: AdaWebPlayerProjectError.self) { try project.validate() }
        project.runtimeAPI = 1
        project.sources.append("main.ada")
        #expect(throws: AdaWebPlayerProjectError.self) { try project.validate() }
    }

    @Test("Fails before writing an unsupported ECS project")
    func unsupportedSystems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject(at: root)
        try (source("First") + "\n@system class Tick { func update(context) {} }").write(
            to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8
        )
        #expect(throws: AdaWebPlayerProjectError.self) {
            try AdaWebPlayerBundle.assemble(template: root.appendingPathComponent("missing"), project: root, output: root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))
    }

    @Test("Scene profile packages AdaScript systems and startup scene bytes")
    func sceneProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        let template = root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        try makeTemplate(at: template)
        try Data(#"{"runtimeAPI":3,"profile":"universal"}"#.utf8).write(to: template.appendingPathComponent("ada-web-player.json"))
        let script = "@system class Tick { func update(context) {} }"
        try script.write(to: projectRoot.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        let scene = "format: ada.scene\nschemaVersion: 1\nscene:\n  id: test\n  name: Test\nentities: []\n"
        try scene.write(to: projectRoot.appendingPathComponent("Assets/Scenes/Main.ascn"), atomically: true, encoding: .utf8)
        var project = AdaWebPlayerProject(title: "Game", entryScene: "Assets/Scenes/Main.ascn", moduleName: "Game", sources: ["Sources/Main.ada"])
        project.files = ["Assets/Scenes/Main.ascn"]
        try JSONEncoder().encode(project).write(to: projectRoot.appendingPathComponent("project.json"))

        let output = root.appendingPathComponent("out")
        try AdaWebPlayerBundle.assemble(template: template, project: projectRoot, output: output)
        let game = output.appendingPathComponent("game")
        #expect(try AdaWebPlayerProject.load(at: game).entryScene == "Assets/Scenes/Main.ascn")
        #expect(try String(contentsOf: game.appendingPathComponent("Assets/Scenes/Main.ascn"), encoding: .utf8) == scene)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: output.appendingPathComponent("ada-resource-manifest.json")))
        #expect(entries.contains(Entry(path: "game/Assets/Scenes/Main.ascn", url: "game/Assets/Scenes/Main.ascn")))
    }

    @Test("AdaEditor scene projects package their sources and runtime settings")
    func editorProjectSceneExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let template = root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".ada"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        try makeTemplate(at: template)
        try Data(#"{"runtimeAPI":3,"profile":"universal"}"#.utf8).write(to: template.appendingPathComponent("ada-web-player.json"))
        try Data("lobby".utf8).write(to: template.appendingPathComponent("player-lobby.js"))
        let settings = #"{"build":{"system":"adascript"},"project":{"name":"SceneGame"},"paths":{"sources":"Sources","assets":"Assets"},"runtime":{"moduleName":"SceneGame","entry":{"scene":"Assets/Scenes/Main.ascn"}}}"#
        try settings.write(to: project.appendingPathComponent(".ada/project.json"), atomically: true, encoding: .utf8)
        try "@system class Tick { func update(context) {} }".write(to: project.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        try "format: ada.scene\n".write(to: project.appendingPathComponent("Assets/Scenes/Main.ascn"), atomically: true, encoding: .utf8)

        let output = root.appendingPathComponent("out")
        try AdaWebPlayerBundle.assemble(template: template, project: project, output: output)
        let game = output.appendingPathComponent("game")
        let manifest = try AdaWebPlayerProject.load(at: game)
        #expect(manifest.profile == "scene")
        #expect(manifest.title == "SceneGame")
        #expect(try Data(contentsOf: game.appendingPathComponent("runtime-settings.json")) == Data(settings.utf8))
        #expect(try String(contentsOf: game.appendingPathComponent("Assets/Scenes/Main.ascn"), encoding: .utf8) == "format: ada.scene\n")
    }

    @Test("Rejects a template whose resource manifest points at missing shader bytes")
    func missingShader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject(at: root.appendingPathComponent("project"))
        let template = root.appendingPathComponent("template")
        try makeTemplate(at: template)
        try Data(#"[{"path":"/engine/text.wgsl","url":"./resources/missing.wgsl"}]"#.utf8)
            .write(to: template.appendingPathComponent("ada-resource-manifest.json"))
        #expect(throws: AdaWebPlayerProjectError.self) {
            try AdaWebPlayerBundle.assemble(template: template, project: root.appendingPathComponent("project"), output: root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))
    }

    @Test("Packages user resource bytes and keeps music out of the eager WASI manifest")
    func userResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        let template = root.appendingPathComponent("template")
        try makeProject(at: projectRoot)
        try makeTemplate(at: template)
        try Data(#"{"runtimeAPI":2,"profile":"views"}"#.utf8).write(to: template.appendingPathComponent("ada-web-player.json"))
        var project = try AdaWebPlayerProject.load(at: projectRoot)
        project.runtimeAPI = 2
        project.assets = [
            .init(id: "picture", kind: .texture, path: "Assets/My #picture.png"),
            .init(id: "font", kind: .font, path: "Assets/Font.ttf"),
            .init(id: "shader", kind: .shader, path: "Assets/Effect.wgsl"),
            .init(id: "music", kind: .audio, path: "Assets/Music.wav")
        ]
        project.materials = [.init(id: "effect", shader: "shader", texture: "picture")]
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        for asset in project.assets ?? [] {
            try Data(asset.id.utf8).write(to: projectRoot.appendingPathComponent(asset.path))
        }
        try JSONEncoder().encode(project).write(to: projectRoot.appendingPathComponent("project.json"))
        let output = root.appendingPathComponent("out")
        try AdaWebPlayerBundle.assemble(template: template, project: projectRoot, output: output)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: output.appendingPathComponent("ada-resource-manifest.json")))
        #expect(!entries.contains { $0.path.hasSuffix("Music.wav") })
        #expect(entries.contains { $0.url == "game/Assets/My%20%23picture.png" })
        for asset in project.assets ?? [] {
            #expect(try Data(contentsOf: output.appendingPathComponent("game/" + asset.path)) == Data(asset.id.utf8))
        }
    }

    @Test("Rejects broken references and old player APIs for resources")
    func invalidResources() {
        var project = AdaWebPlayerProject(title: "Game", entryView: "Game", sources: ["Main.ada"])
        project.assets = [.init(id: "picture", kind: .texture, path: "Assets/Picture.png")]
        #expect(throws: AdaWebPlayerProjectError.self) { try project.validate() }
        project.runtimeAPI = 2
        project.materials = [.init(id: "effect", shader: "missing", texture: "picture")]
        #expect(throws: AdaWebPlayerProjectError.self) { try project.validate() }
        project.materials = []
        project.assets = [.init(id: "picture", kind: .texture, path: "../Outside.png")]
        #expect(throws: AdaWebPlayerProjectError.self) { try project.validate() }
    }

    @Test("Rejects a resource symlink escaping the game directory")
    func escapingResource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("game"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("game/picture.png"), withDestinationURL: root.appendingPathComponent("outside.png"))
        let project = AdaWebPlayerProject(title: "Game", entryView: "Game", sources: ["Main.ada"])
        #expect(throws: AdaWebPlayerProjectError.self) {
            try project.resourceURL("picture.png", at: root.appendingPathComponent("game"))
        }
    }

    private func makeProject(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let project = AdaWebPlayerProject(title: "Game", entryView: "Game", sources: ["Sources/Main.ada"])
        try JSONEncoder().encode(project).write(to: directory.appendingPathComponent("project.json"))
        try source("First").write(to: directory.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
    }

    private func makeTemplate(at directory: URL) throws {
        for path in ["index.html", "main.js", "AdaWebPlayer.wasm", "runtime.mjs", "bridge-js.js", "browser-wasi-shim/dist/index.js"] {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test player bytes".utf8).write(to: file)
        }
        try Data("[]".utf8).write(to: directory.appendingPathComponent("ada-resource-manifest.json"))
        try Data(#"{"runtimeAPI":1,"profile":"views"}"#.utf8).write(to: directory.appendingPathComponent("ada-web-player.json"))
    }

    private func source(_ text: String) -> String {
        "@view class Game { func body() { Text(\"\(text)\"); } }"
    }

    private struct Entry: Decodable, Equatable {
        let path: String
        let url: String
    }
}
