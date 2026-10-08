@_spi(AdaEngine) import AdaEngine
import Math

extension EditorSceneViewportModel {
    func transformGizmo() -> EditorTransformGizmo? {
        guard
            !isPerspectiveTransitionActive,
            let selectedEditorID,
            let entity = sceneModel?.entities.first(where: { $0.id == selectedEditorID }), entity.enabled,
            let payload = entity.components[EditorBuiltInComponentType.transform],
            let transform = try? EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform,
            let parent = entity.parent.map({ gizmoWorldMatrix(for: $0) }) ?? .some(.identity)
        else {
            return nil
        }
        return EditorTransformGizmo(
            tool: activeTool,
            transform: transform,
            parent: parent,
            camera: cameraState(for: viewportSize),
            size: viewportSize,
            is2D: displayMode == .twoD
        )
    }

    func gizmoWorldMatrix(for editorID: String) -> Transform3D? {
        guard let model = sceneModel else {
            return nil
        }
        var currentID: String? = editorID
        var visited: Set<String> = []
        var result = Transform3D.identity
        while let id = currentID {
            guard
                visited.insert(id).inserted,
                let entity = model.entities.first(where: { $0.id == id }), entity.enabled
            else {
                return nil
            }
            if let payload = entity.components[EditorBuiltInComponentType.transform],
                let transform = try? EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform {
                result = transform.matrix * result
            }
            currentID = entity.parent
        }
        return result
    }
}
