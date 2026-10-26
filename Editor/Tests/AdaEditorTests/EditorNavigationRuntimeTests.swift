@testable import AdaEditor
import AdaEngine
import Foundation
import Testing

@MainActor
@Suite
struct EditorNavigationRuntimeTests {
    @Test func navigationIsOptInAndBringsPhysics() throws {
        let solo = try EditorAdaScriptRuntimePluginResolver.resolve(AdaProjectRuntimePlugins(preset: .ui))
        #expect(!solo.contains(.navigation3D))
        let enabled = try EditorAdaScriptRuntimePluginResolver.resolve(AdaProjectRuntimePlugins(preset: .ui, enable: [.navigation3D]))
        #expect(enabled.contains(.navigation3D) && enabled.contains(.physics3D) && enabled.contains(.core3D))
    }

    @Test func sceneAuthoringDecodesMapAndAgentWithoutPersistingRuntimePaths() throws {
        EditorComponentRegistry.registerBuiltIns()
        let source = try #require(EditorComponentRegistry.decode(typeName: "AdaScene.NavigationMap3DSource", payload: ["source": .string("@res://floor.navmesh")]) as? NavigationMap3DSource)
        #expect(source.source == "@res://floor.navmesh")
        let agent = try #require(EditorComponentRegistry.decode(typeName: "AdaScene.NavigationAgent3DComponent", payload: ["maximumSpeed": .double(2.2), "arrivalTolerance": .double(0.65)]) as? NavigationAgent3DComponent)
        #expect(abs(agent.maximumSpeed - 2.2) < 0.0001 && agent.pathPointCount == 0)
        let decoded = try JSONDecoder().decode(NavigationAgent3DComponent.self, from: JSONEncoder().encode(agent))
        #expect(decoded.maximumSpeed == agent.maximumSpeed && !decoded.hasPath)
    }
}
