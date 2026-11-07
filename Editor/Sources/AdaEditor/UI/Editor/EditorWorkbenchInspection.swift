@_spi(AdaEngine) import AdaEngine
import AdaInput
import Foundation
import Math

/// Read-only access to the rendered scene surface and open document of a workbench.
@MainActor
package final class EditorWorkbenchInspection {
    package struct SceneState: Codable, Equatable {
        package let position: [Float]?
        package let parent: String?
        package let undoCount: Int
    }

    private let project: EditorProjectReference
    private let model: EditorViewModel
    weak var viewport: EditorSceneViewportModel?
    package private(set) var viewportInputCount = 0
    package private(set) var lastViewportInput: MouseEvent?

    package init(project: EditorProjectReference) {
        EditorComponentRegistry.registerBuiltIns()
        self.project = project
        model = EditorViewModel(project: project)
    }

    package var content: some View {
        EditorView(project: project, viewModel: model)
            .environment(\.workbenchInspection, self)
    }

    package func sceneState(entity id: String, preview: Bool = false) -> SceneState? {
        guard let document = model.workbench.activeSceneDocument,
              let scene = preview ? viewport?.sceneModel : document.sceneModel,
              let entity = scene.entities.first(where: { $0.id == id }) else { return nil }
        let transform = entity.components[EditorBuiltInComponentType.transform].flatMap {
            try? EditorComponentPayloadDecoder.decode(Transform.self, payload: $0) as? Transform
        }
        return SceneState(
            position: transform.map { [$0.position.x, $0.position.y, $0.position.z] },
            parent: entity.parent,
            undoCount: model.workbench.sceneUndoHistory[document.id]?.count ?? 0
        )
    }

    package var hasLoadedScene: Bool {
        guard let scene = model.workbench.activeSceneDocument else {
            return false
        }
        return !scene.isLoading && scene.sceneModel != nil
    }

    package var selectedEntity: String? { viewport?.selectedEditorID }

    package func translateXAnchor() -> Point? {
        guard let viewport, let id = viewport.selectedEditorID,
              let committed = sceneState(entity: id)?.position,
              sceneState(entity: id, preview: true)?.position == committed,
              viewport.presentedGizmo != nil, let gizmo = viewport.interactionGizmo(),
              let current = viewport.transformGizmo(size: gizmo.size), current.viewProjection == gizmo.viewProjection,
              (current.origin - gizmo.origin).squaredLength < 0.000001,
              gizmo.tool == .translate, let shape = gizmo.shapes.first(where: { $0.handle == .x }),
              let start = shape.points.first, let end = shape.points.last else { return nil }
        for fraction: Float in [0.5, 0.75, 0.25, 1] {
            let point = start + (end - start) * fraction
            if gizmo.hitTest(point) == .x {
                return Point(point.x / gizmo.size.width, point.y / gizmo.size.height)
            }
        }
        return nil
    }

    func observedInput(_ event: MouseEvent) {
        lastViewportInput = event
        viewportInputCount += 1
    }
}

extension EnvironmentValues {
    @Entry var workbenchInspection: EditorWorkbenchInspection?
}
