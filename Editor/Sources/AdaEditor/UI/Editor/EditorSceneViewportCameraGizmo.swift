@_spi(AdaEngine) import AdaEngine
import Math

@MainActor
enum EditorSceneViewportCameraGizmo {
    private static let nearDistance: Float = 0.3
    private static let farDistance: Float = 3.8

    static func draw(
        in context: inout UIGraphicsContext,
        world: World,
        editorIDsByEntityID: [Entity.ID: String],
        viewportModel: EditorSceneViewportModel,
        size: Size,
        theme: Theme
    ) {
        for entity in world.getEntities() {
            guard
                let camera = entity.components[Camera.self],
                let editorID = editorIDsByEntityID[entity.id],
                let cameraTransform = viewportModel.gizmoWorldMatrix(for: editorID)
            else {
                continue
            }

            drawCamera(
                camera,
                transform: cameraTransform,
                viewportModel: viewportModel,
                size: size,
                color: Color.fromHex(0xFFC75A).opacity(camera.isActive ? 0.92 : 0.48),
                theme: theme,
                in: &context
            )
        }
    }

    private static func drawCamera(
        _ camera: Camera,
        transform: Transform3D,
        viewportModel: EditorSceneViewportModel,
        size: Size,
        color: Color,
        theme: Theme,
        in context: inout UIGraphicsContext
    ) {
        if viewportModel.displayMode == .twoD {
            if let corners = orthographicFrame(camera: camera, transform: transform, viewport: size) {
                drawFrame(corners, model: viewportModel, size: size, color: color, in: &context)
            }
            // Keep the camera recognizable even when zoomed far out.
            if let point = viewportModel.project(transform.origin, size: size) {
                context.stroke(
                    RectangleShape().path(in: Rect(x: point.x - 7, y: point.y - 5, width: 14, height: 10)),
                    with: color,
                    style: StrokeStyle(lineWidth: 1.5)
                )
            }
            return
        }
        let origin = transform.origin
        let right = transform.x.xyz.normalized
        let up = transform.y.xyz.normalized
        let forward = transform.z.xyz.normalized
        let projection = frustumDimensions(for: camera.projection, viewport: size)

        let bodyCenter = origin - forward * 0.12
        let bodyCorners = frameCorners(
            center: bodyCenter,
            right: right,
            up: up,
            halfWidth: 0.16,
            halfHeight: 0.11
        )
        let nearCenter = origin + forward * nearDistance
        let nearCorners = frameCorners(
            center: nearCenter,
            right: right,
            up: up,
            halfWidth: projection.nearHalfWidth,
            halfHeight: projection.nearHalfHeight
        )
        let farCenter = origin + forward * farDistance
        let farCorners = frameCorners(
            center: farCenter,
            right: right,
            up: up,
            halfWidth: projection.farHalfWidth,
            halfHeight: projection.farHalfHeight
        )

        drawFrame(bodyCorners, model: viewportModel, size: size, color: color, in: &context)
        drawFrame(nearCorners, model: viewportModel, size: size, color: color.opacity(0.78), in: &context)
        drawFrame(farCorners, model: viewportModel, size: size, color: color.opacity(0.9), in: &context)

        for index in 0..<4 {
            viewportModel.drawProjectedSegment(
                from: bodyCorners[index],
                to: nearCorners[index],
                in: &context,
                size: size,
                lineWidth: 1.5,
                color: color
            )
            viewportModel.drawProjectedSegment(
                from: nearCorners[index],
                to: farCorners[index],
                in: &context,
                size: size,
                lineWidth: 1.5,
                color: color.opacity(0.82)
            )
        }

        viewportModel.drawProjectedSegment(
            from: nearCenter,
            to: farCenter,
            in: &context,
            size: size,
            lineWidth: 1,
            color: theme.editorColors.text.opacity(0.82)
        )
    }

    static func logicalSize(camera: Camera, fallback: Size) -> Size {
        let size = camera.logicalViewport.rect.size
        return size.width > 0 && size.height > 0 ? size : fallback
    }

    /// Authored camera coverage in world units, including a non-centered viewport origin.
    static func orthographicFrame(camera: Camera, transform: Transform3D, viewport: Size) -> [Vector3]? {
        guard case let .orthographic(projection) = camera.projection else {
            return nil
        }
        let size = logicalSize(camera: camera, fallback: viewport)
        let width = size.width / projection.scale
        let height = size.height / projection.scale
        let left = -width * projection.viewportOrigin.x
        let bottom = -height * projection.viewportOrigin.y
        return [
            Vector3(left, bottom, 0),
            Vector3(left + width, bottom, 0),
            Vector3(left + width, bottom + height, 0),
            Vector3(left, bottom + height, 0),
        ].map { (transform * Vector4($0, 1)).xyz }
    }

    private static func frustumDimensions(for projection: Projection, viewport: Size) -> FrustumDimensions {
        switch projection {
        case let .perspective(perspective):
            let aspect = perspective.aspectRation.isFinite && perspective.aspectRation > 0
                ? perspective.aspectRation
                : max(0.1, viewport.width / max(1, viewport.height))
            let tangent = Math.tanf(perspective.fieldOfView.radians * 0.5)
            let farHalfHeight = min(2.6, max(0.12, tangent * farDistance))
            let nearHalfHeight = farHalfHeight * nearDistance / farDistance
            return FrustumDimensions(
                nearHalfWidth: nearHalfHeight * aspect,
                nearHalfHeight: nearHalfHeight,
                farHalfWidth: farHalfHeight * aspect,
                farHalfHeight: farHalfHeight
            )
        case let .orthographic(orthographic):
            let aspect = max(0.1, viewport.width / max(1, viewport.height))
            let halfHeight = min(2.6, max(0.35, viewport.height / max(0.1, orthographic.scale) * 0.012))
            return FrustumDimensions(
                nearHalfWidth: halfHeight * aspect,
                nearHalfHeight: halfHeight,
                farHalfWidth: halfHeight * aspect,
                farHalfHeight: halfHeight
            )
        case .custom:
            let aspect = max(0.1, viewport.width / max(1, viewport.height))
            let farHalfHeight = Math.tanf(Angle.degrees(60).radians * 0.5) * farDistance
            let nearHalfHeight = farHalfHeight * nearDistance / farDistance
            return FrustumDimensions(
                nearHalfWidth: nearHalfHeight * aspect,
                nearHalfHeight: nearHalfHeight,
                farHalfWidth: farHalfHeight * aspect,
                farHalfHeight: farHalfHeight
            )
        }
    }

    private static func frameCorners(
        center: Vector3,
        right: Vector3,
        up: Vector3,
        halfWidth: Float,
        halfHeight: Float
    ) -> [Vector3] {
        [
            center - right * halfWidth - up * halfHeight,
            center + right * halfWidth - up * halfHeight,
            center + right * halfWidth + up * halfHeight,
            center - right * halfWidth + up * halfHeight,
        ]
    }

    private static func drawFrame(
        _ corners: [Vector3],
        model: EditorSceneViewportModel,
        size: Size,
        color: Color,
        in context: inout UIGraphicsContext
    ) {
        for index in 0..<4 {
            model.drawProjectedSegment(
                from: corners[index],
                to: corners[(index + 1) % 4],
                in: &context,
                size: size,
                lineWidth: 1.5,
                color: color
            )
        }
    }

    private struct FrustumDimensions {
        var nearHalfWidth: Float
        var nearHalfHeight: Float
        var farHalfWidth: Float
        var farHalfHeight: Float
    }
}
