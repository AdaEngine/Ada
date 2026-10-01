import AdaEngine
import AdaMultiplayer
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Multiplayer HUD runtime", .serialized)
struct EditorMultiplayerHUDRuntimeTests {
    @Test("Native overlays keep their view and detach when their entity is disabled or removed")
    func overlayLifetimeFollowsEntity() {
        let world = World(name: "Overlay lifetime")
        let view = UIView()
        let entity = world.spawn { UIComponent(view: view, behaviour: .overlay) }
        let session = EditorSceneUIOverlaySession()
        session.prepare(world)
        #expect(session.views.count == 1)
        #expect(session.views.first?.view === view)
        session.prepare(world)
        #expect(session.views.first?.view === view)
        entity.isActive = false
        session.prepare(world)
        #expect(session.views.isEmpty)
        entity.isActive = true
        session.prepare(world)
        #expect(session.views.first?.view === view)
        world.remove(UIComponent.self, from: entity.id)
        session.prepare(world)
        #expect(session.views.isEmpty)
    }

    @Test("Network resources resolve before scriptable UI is registered")
    func registersNetworkResourceBeforeHUD() async throws {
        let identifier = "test.network-hud." + UUID().uuidString
        let source = AdaScriptSource(path: "HUD.ada", source: """
        @scriptable(id: "\(identifier)")
        class NetworkHUD {
            @res var multiplayer: AdaScriptMultiplayerState;
            @export var role = "pending";
            func update(context) { role = multiplayer.role; }
        }
        """)
        var project = AdaProject(schemaVersion: 3)
        project.runtime.entry.view = nil
        project.runtime.plugins.enable = [.multiplayer]
        let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: project, sources: [source]).playRuntime
        let plugins = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
        let artifact = EditorAdaScriptProjectBuildArtifact(
            assetsDirectory: FileManager.default.temporaryDirectory,
            entry: project.runtime.entry,
            moduleName: project.runtime.moduleName,
            plugins: plugins,
            report: .init(
                entryDescription: "Network HUD", entryView: nil, moduleName: project.runtime.moduleName,
                pluginIDs: ["multiplayer"], sourceCount: 1, startupScene: nil, startupSystem: nil,
                systemCount: 0, viewCount: 0
            ),
            sceneModel: nil,
            scenePlayRuntime: runtime,
            sources: [source],
            window: project.runtime.window
        )
        // The original order threw unknownResource here, before plugins could start.
        _ = try EditorAdaScriptProjectRuntimeView(artifact: artifact)
        let script = try ScriptableObjectRegistry.make(named: identifier)
        let world = World(name: "Network HUD regression")
        let app = AppWorlds(main: world)
        InputPlugin(actions: []).setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.insertResource(AdaScriptMultiplayerState(role: .host, localPeerID: PeerID(rawValue: UUID())))
        world.spawn { ScriptableComponents(scripts: [script]) }
        await world.runScheduler(.update)
        #expect(script.readExportedField("role") == .string("host"))
    }
}
