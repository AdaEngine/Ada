@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorGizmoRemovalTests {
    @Test("Inspector removes enabled and disabled gizmos from the live scene and saved file", arguments: [true, false])
    func removeGizmo(isEnabled: Bool) async throws {
        prepareRenderer()
        var scene = EditorSceneModel.default(projectName: "Gizmo removal")
        let selected = scene.addEntity(preset: .empty)
        let other = scene.addEntity(preset: .empty)
        scene.editor?.selectedEntity = selected.id
        var content = try EditorSceneYAMLDocument.upsertGizmo(
            EditorGizmo(name: "Selected", kind: .custom, isEnabled: isEnabled),
            entityID: selected.id,
            in: scene.encodedYAML()
        )
        content = try EditorSceneYAMLDocument.upsertGizmo(EditorGizmo(name: "Other", kind: .custom), entityID: other.id, in: content)
        let initialScene = try EditorSceneModel.decode(from: content)
        let world = World(name: "GizmoRemovalRuntime")
        let inspector = EditorInspectorSidebarViewModel()
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        viewport.configure(sceneContent: content, onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { content = $0 })
        viewport.attachSceneWorld(world, loadResult: EditorSceneFileLoader.load(content: content, into: world))
        inspector.removeComponent = { type in
            do {
                var updated = try EditorSceneModel.decode(from: content)
                updated.removeComponent(typeName: type, from: selected.id)
                content = try updated.encodedYAML()
                viewport.configure(sceneContent: content, onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { content = $0 })
            } catch {
                Issue.record(error)
            }
        }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let remove = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.RemoveGizmo")
        _ = try container.uiScrollToNode(matching: remove)
        _ = try container.uiTapNode(matching: remove)
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(inspector.selectedEntity?.editorID == selected.id)
        #expect(inspector.selectedEntity?.hasExplicitGizmo == false)
        #expect(inspector.selectedEntity?.gizmo == nil)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Inspector.AddGizmo"))
        #expect(container.uiFindNodes(matching: remove).isEmpty)
        let remainingGizmos = world.getEntities().compactMap { $0.components[EditorGizmo.self]?.name }
        #expect(remainingGizmos == ["Other"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gizmo-removal-\(UUID().uuidString).ascn")
        defer { try? FileManager.default.removeItem(at: url) }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let selectedComponents = try #require(reopened.entities.first { $0.id == selected.id }?.components)
        #expect(selectedComponents[EditorSceneYAMLDocument.editorGizmoComponentName] == nil)
        #expect(selectedComponents[EditorBuiltInComponentType.transform] == initialScene.entities.first { $0.id == selected.id }?.components[EditorBuiltInComponentType.transform])
        #expect(reopened.entities.first { $0.id == other.id }?.components[EditorSceneYAMLDocument.editorGizmoComponentName] != nil)
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GizmoRemovalUI")))
        }
    }
}
