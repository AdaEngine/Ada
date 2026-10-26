@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing
@testable import AdaEditor

@Suite("Editor project storage identity", .serialized)
struct EditorProjectStorageIdentityTests {
    @MainActor
    @Test("Real project preparation and scoped asset roots survive a folder rename")
    func preparedProjectDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: original.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try """
        @component(id: "test.marker") struct Marker { @export var value = 0; }
        @system(id: "test.identity-bootstrap", scheduler: "startup")
        class IdentityBootstrap { func update(context) {} }
        """.write(
            to: original.appendingPathComponent("Sources/Marker.ada"), atomically: true, encoding: .utf8
        )
        var project = fixture()
        project.project.id = "persisted-project-id"
        project.project.bundleIdentifier = "org.example.identity"
        project.runtime.entry.startupSystem = "test.identity-bootstrap"
        try ProjectSystem.saveProject(project, at: original)
        let first = try EditorAdaScriptProjectBuilder().prepare(project: project, at: original)
        let moved = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        let second = try EditorAdaScriptProjectBuilder().prepare(project: project, at: moved)
        #expect(first.storageIdentifier == "org.example.identity")
        #expect(second.storageIdentifier == first.storageIdentifier)
        let firstDirectories = try first.assetDirectories()
        let secondDirectories = try second.assetDirectories()
        #expect(firstDirectories.userDataDirectory == secondDirectories.userDataDirectory)
        #expect(firstDirectories.cacheDirectory == secondDirectories.cacheDirectory)
        let scenePlay = try EditorSceneViewportView.assetDirectories(for: second.assetsDirectory)
        #expect(scenePlay.assetsDirectory == second.assetsDirectory)
        #expect(scenePlay.userDataDirectory == firstDirectories.userDataDirectory)
        #expect(scenePlay.cacheDirectory == firstDirectories.cacheDirectory)
        let app = AppWorlds(main: World(name: "Explicit storage identity"))
        AssetsPlugin(directories: secondDirectories).setup(in: app)
        app.withExecutionContext {
            #expect(AssetsManager.resolveAssetURL(at: "@user://slot.json") == firstDirectories.userDataDirectory.appendingPathComponent("slot.json"))
        }
        project.project.bundleIdentifier = "../invalid-project-id"
        try JSONEncoder().encode(project).write(to: ProjectSystem.metadataURL(forProjectAt: moved))
        #expect(throws: ProjectDirectoriesError.self) { try EditorSceneViewportView.assetDirectories(for: second.assetsDirectory) }
    }

    @Test("Explicit IDs validate, while minimal legacy projects remain supported")
    func identityResolution() throws {
        var project = fixture()
        #expect(try EditorProjectStorageIdentity.resolve(project) == nil)
        #expect(try EditorProjectStorageIdentity.resolve(project, nativeFallback: true) == "LegacyGame")
        project.project.name = "Legacy game / display name"
        let fallback = try #require(try EditorProjectStorageIdentity.resolve(project, nativeFallback: true))
        try ProjectDirectories.validateStorageIdentifier(fallback)
        project.project.id = "persisted-id"
        #expect(try EditorProjectStorageIdentity.resolve(project) == "persisted-id")
        project.project.bundleIdentifier = "org.example.preferred"
        #expect(try EditorProjectStorageIdentity.resolve(project) == "org.example.preferred")
        for invalid in ["../escape", "a/b", "a\\b", ""] {
            project.project.bundleIdentifier = invalid
            #expect(throws: ProjectDirectoriesError.self) { try EditorProjectStorageIdentity.resolve(project) }
        }
        project.project.bundleIdentifier = "org.example.valid"
        project.project.id = "../invalid-secondary-id"
        #expect(throws: ProjectDirectoriesError.self) { try EditorProjectStorageIdentity.resolve(project) }
    }

    @Test("Generated native and interpreted players use the same validated storage identity")
    func generatedPlayer() throws {
        var project = fixture()
        project.project.bundleIdentifier = "org.example.exported"
        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
        for interpreted in [false, true] {
            let player = try EditorAdaScriptNativeExporter.player(project: project, sources: [], plugins: plugins, destination: .macOS, interpreted: interpreted)
            #expect(player.contains("AssetsPlugin(directories: try ProjectDirectories("))
            #expect(player.contains("storageIdentifier: \"org.example.exported\""))
            let studio = try #require(try EditorProjectStorageIdentity.resolve(project))
            let native = try #require(try EditorProjectStorageIdentity.resolve(project, nativeFallback: true))
            let first = try ProjectDirectories(source: URL(fileURLWithPath: "/tmp/Project"), assetsDirectory: URL(fileURLWithPath: "/tmp/Project/Assets"), storageIdentifier: studio)
            let second = try ProjectDirectories(source: URL(fileURLWithPath: "/tmp/Export.bundle"),
                assetsDirectory: URL(fileURLWithPath: "/tmp/Export.bundle/GameAssets"), storageIdentifier: native)
            #expect(first.userDataDirectory == second.userDataDirectory)
            #expect(first.cacheDirectory == second.cacheDirectory)
        }
    }

    @Test("A packaged macOS app honors the project's bundle identifier")
    func packagedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackagedIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let binaries = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try Data([0]).write(to: binaries.appendingPathComponent("AdaNativeGame"))
        let bundle = root.appendingPathComponent("Game.app")
        try EditorAdaScriptNativeExporter.packageApp(binaryDirectory: binaries, to: bundle, title: "Game", bundleIdentifier: "org.example.packaged")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == "org.example.packaged")
    }

    private func fixture() -> AdaProject {
        var project = AdaProject(schemaVersion: 3)
        project.project.name = "LegacyGame"
        project.build.system = .adaScript
        project.runtime.moduleName = "IdentityFixture"
        project.runtime.entry.view = nil
        return project
    }
}
