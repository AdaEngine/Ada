@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Math

/// A retained component view laid out in logical pixels before scene zoom is applied.
@MainActor
struct EditorSceneUIPreview {
    let view: UIView
    let contentSize: Size
    let transform: Transform3D

    static func make(
        world: World,
        editorIDsByEntityID: [Entity.ID: String],
        viewportModel: EditorSceneViewportModel,
        size: Size
    ) -> [Self] {
        let entities = world.getEntities()
        let cameraEntity = entities.filter {
            editorIDsByEntityID[$0.id] != nil && $0.isActive && $0.components[Camera.self]?.isActive == true
        }.max {
            ($0.components[Camera.self]?.renderOrder ?? 0) < ($1.components[Camera.self]?.renderOrder ?? 0)
        }
        let camera = cameraEntity?.components[Camera.self]
        let cameraMatrix = cameraEntity.flatMap { editorIDsByEntityID[$0.id] }.flatMap(viewportModel.gizmoWorldMatrix)
        let runtime = world.getResource(UIComponentRuntimeResource.self)?.runtime
        return entities.sorted {
            ($0.components[Transform.self]?.position.z ?? 0) < ($1.components[Transform.self]?.position.z ?? 0)
        }.compactMap { entity in
            guard
                entity.isActive,
                let editorID = editorIDsByEntityID[entity.id],
                let matrix = viewportModel.gizmoWorldMatrix(for: editorID),
                let component = entity.components[UIComponent.self],
                let view = try? component.resolveView(runtime: runtime)
            else {
                return nil
            }
            let contentSize = camera.map { EditorSceneViewportCameraGizmo.logicalSize(camera: $0, fallback: size) } ?? size
            let origin: Vector3
            let right: Vector3
            let up: Vector3
            if component.behaviour == .overlay,
                let camera, let cameraMatrix,
                let corners = EditorSceneViewportCameraGizmo.orthographicFrame(camera: camera, transform: cameraMatrix, viewport: size) {
                origin = corners[3]
                right = (corners[2] - corners[3]) / contentSize.width
                up = (corners[3] - corners[0]) / contentSize.height
            } else {
                origin = matrix.origin - matrix.x.xyz * (contentSize.width * 0.5) + matrix.y.xyz * (contentSize.height * 0.5)
                right = matrix.x.xyz
                up = matrix.y.xyz
            }
            guard
                contentSize.width > 0, contentSize.height > 0,
                let point = viewportModel.project(origin, size: size),
                let x = viewportModel.project(origin + right, size: size),
                let y = viewportModel.project(origin + up, size: size)
            else {
                return nil
            }
            return Self(
                view: view,
                contentSize: contentSize,
                transform: Transform3D(columns: [
                    Vector4(x.x - point.x, point.y - x.y, 0, 0),
                    Vector4(y.x - point.x, point.y - y.y, 0, 0),
                    Vector4(0, 0, 1, 0),
                    Vector4(point.x, -point.y, 0, 1),
                ])
            )
        }
    }
}

struct EditorSceneUIPreviewSurface: UIViewRepresentable {
    let viewportModel: EditorSceneViewportModel

    func makeUIView(in _: Context) -> EditorSceneUIPreviewHost { EditorSceneUIPreviewHost() }

    func updateUIView(_ view: EditorSceneUIPreviewHost, in _: Context) {
        view.viewportModel = viewportModel
        view.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, view _: EditorSceneUIPreviewHost, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class EditorSceneUIPreviewHost: UIView {
    weak var viewportModel: EditorSceneViewportModel?
    private var previews: [EditorSceneUIPreview] = []

    override init() {
        super.init()
        isInteractionEnabled = false
    }

    required init(frame: Rect) {
        super.init(frame: frame)
        isInteractionEnabled = false
    }

    override func update(_ deltaTime: Float) {
        let updated = viewportModel?.uiPreviews(size: bounds.size) ?? []
        let retained = Set(updated.map { ObjectIdentifier($0.view) })
        for preview in previews where !retained.contains(ObjectIdentifier(preview.view)) {
            preview.view.removeFromParentView()
        }
        for preview in updated {
            if preview.view.parentView !== self {
                addSubview(preview.view)
            }
            let frame = Rect(origin: .zero, size: preview.contentSize)
            if preview.view.frame != frame {
                preview.view.frame = frame
                preview.view.layoutSubviews()
            }
        }
        let changed = previews.count != updated.count || zip(previews, updated).contains {
            $0.view !== $1.view || $0.contentSize != $1.contentSize || $0.transform != $1.transform
        }
        previews = updated
        super.update(deltaTime)
        if changed { setNeedsDisplay() }
    }

    override func draw(with context: UIGraphicsContext) {
        guard !isHidden else { return }
        for preview in previews {
            var recorded = UIGraphicsContext()
            recorded.environment = context.environment
            recorded.opacity = context.opacity
            recorded.windowId = context.windowId
            preview.view.draw(with: recorded)
            let local = Transform3D(translation: [frame.minX, -frame.minY, 0]) * preview.transform
            let placement = context.transform * local
            var clipped = context
            // UI overlays must stay within the authored camera's rectangle.
            clipped.concatenate(local)
            clipped.pushClipPath(RectangleShape().path(in: Rect(origin: .zero, size: preview.contentSize)))
            context.drawContents(of: recorded, transform: placement)
            clipped.popClipPath()
        }
    }
}
