@_spi(AdaEngine) import AdaEngine

enum EditorGizmoOverlayModel {
    struct Icon: Equatable {
        var editorEntityID: String
        var kind: EditorGizmoKind
        var name: String
        var position: Vector3
        var size: Float
        var color: Color?
        var isExplicit: Bool
    }

    @MainActor
    static func icons(in world: World, editorIDsByEntityID: [Entity.ID: String]) -> [Icon] {
        world.getEntities()
            .compactMap { entity in
                guard
                    let editorID = editorIDsByEntityID[entity.id],
                    let transform = entity.components[Transform.self],
                    let resolved = visibleGizmo(for: entity)
                else {
                    return nil
                }

                return Icon(
                    editorEntityID: editorID,
                    kind: resolved.gizmo.kind,
                    name: resolved.gizmo.name,
                    position: transform.position,
                    size: resolved.gizmo.size,
                    color: resolved.gizmo.color,
                    isExplicit: resolved.isExplicit
                )
            }
    }

    @MainActor
    static func visibleGizmo(for entity: Entity) -> (gizmo: EditorGizmo, isExplicit: Bool)? {
        if let gizmo = entity.components[EditorGizmo.self] {
            return gizmo.isEnabled ? (gizmo, true) : nil
        }

        if entity.components[Light2D.self] != nil || entity.components[SpotLightComponent.self] != nil || entity.components[PointLightComponent.self] != nil
            || entity.components[DirectionalLightComponent.self] != nil {
            return (EditorGizmo(name: entity.name, kind: .light), false)
        }

        if entity.components[Camera.self] != nil {
            return (EditorGizmo(name: entity.name, kind: .camera), false)
        }

        if entity.components[AudioComponent.self] != nil {
            return (EditorGizmo(name: entity.name, kind: .audio), false)
        }

        return nil
    }
}
