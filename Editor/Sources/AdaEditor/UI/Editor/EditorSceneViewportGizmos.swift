@_spi(AdaEngine) import AdaEngine
import Math

extension EditorSceneViewportModel {
    struct PresentedGizmo {
        let selection: String?
        let tool: EditorSceneViewportTool
        let mode: EditorSceneViewportDisplayMode
        let geometry: EditorTransformGizmo?
    }

    func captureGizmo(_ geometry: EditorTransformGizmo?) -> PresentedGizmo {
        PresentedGizmo(selection: selectedEditorID, tool: activeTool, mode: displayMode, geometry: geometry)
    }

    // Once a scene frame is displayed, pointer input must use its geometry,
    // including a frame that deliberately contains no transform handles.
    func interactionGizmo() -> EditorTransformGizmo? {
        guard let presentedGizmo else { return transformGizmo() }
        guard presentedGizmo.selection == selectedEditorID, presentedGizmo.tool == activeTool,
              presentedGizmo.mode == displayMode, !isPerspectiveTransitionActive else { return nil }
        return presentedGizmo.geometry
    }

    func gizmoPosition(_ point: Point, size: Size) -> Point {
        Point(x: point.x * size.width / max(1, viewportSize.width), y: point.y * size.height / max(1, viewportSize.height))
    }

    func transformGizmo(size: Size? = nil) -> EditorTransformGizmo? {
        guard
            !isAnnotating,
            !terrainEditing.isEnabled,
            !isPerspectiveTransitionActive,
            let selectedEditorID,
            let entity = sceneModel?.entities.first(where: { $0.id == selectedEditorID }), entity.enabled,
            let payload = entity.components[EditorBuiltInComponentType.transform],
            let transform = try? EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform,
            let parent = entity.parent.map({ gizmoWorldMatrix(for: $0) }) ?? .some(.identity)
        else {
            return nil
        }
        let size = size ?? viewportSize
        return EditorTransformGizmo(
            tool: activeTool,
            transform: transform,
            parent: parent,
            camera: cameraState(for: size),
            size: size,
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
