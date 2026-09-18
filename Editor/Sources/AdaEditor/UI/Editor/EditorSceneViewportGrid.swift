@_spi(AdaEngine) import AdaEngine
import Math

struct EditorSceneViewportTransitionProjection: CameraProjection {
    var matrix: Transform3D
    var near: Float = -10_000
    var far: Float = 10_000

    func makeClipView() -> Transform3D {
        matrix
    }

    mutating func updateView(width: Float, height: Float) {
        _ = width
        _ = height
    }
}

struct EditorSceneViewportCoordinateRuler {
    enum Axis: String, Sendable {
        case x
        case y
    }

    struct Label: Identifiable, Sendable {
        var id: String { "\(axis.rawValue):\(value)" }
        var axis: Axis
        var value: Float
        var position: Point
        var text: String
    }

    var opacity: Float
    var labels: [Label]
}

extension EditorSceneViewportModel {
    func draw2DGrid(in context: inout UIGraphicsContext, size: Size, theme: Theme, opacity: Float = 1) {
        let safeZoom = max(0.001, twoDZoom)
        let minorStep = niceGridStep(minPixels: 28, zoom: safeZoom)
        let majorStep = minorStep * 5
        let halfWidth = size.width * 0.5 / safeZoom
        let halfHeight = size.height * 0.5 / safeZoom
        let minX = twoDCenter.x - halfWidth
        let maxX = twoDCenter.x + halfWidth
        let minY = twoDCenter.y - halfHeight
        let maxY = twoDCenter.y + halfHeight

        draw2DLines(
            in: &context,
            size: size,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            step: minorStep,
            lineWidth: 1,
            color: theme.editorColors.border.opacity(0.28 * opacity)
        )
        draw2DLines(
            in: &context,
            size: size,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            step: majorStep,
            lineWidth: 1,
            color: theme.editorColors.border.opacity(0.42 * opacity)
        )

        if minY <= 0 && maxY >= 0 {
            let y = worldToScreen(Vector2(0, 0), size: size).y
            context.drawLine(
                start: Vector2(0, y),
                end: Vector2(size.width, y),
                lineWidth: 2,
                color: theme.editorColors.blue.opacity(0.55 * opacity)
            )
        }
        if minX <= 0 && maxX >= 0 {
            let x = worldToScreen(Vector2(0, 0), size: size).x
            context.drawLine(
                start: Vector2(x, 0),
                end: Vector2(x, size.height),
                lineWidth: 2,
                color: theme.editorColors.purple.opacity(0.52 * opacity)
            )
        }
    }

    func draw2DLines(
        in context: inout UIGraphicsContext,
        size: Size,
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float,
        step: Float,
        lineWidth: Float,
        color: Color
    ) {
        guard step > 0 else {
            return
        }

        var x = floor(minX / step) * step
        while x <= maxX {
            let start = worldToScreen(Vector2(x, minY), size: size)
            let end = worldToScreen(Vector2(x, maxY), size: size)
            drawViewportLine(from: start, to: end, lineWidth: lineWidth, color: color, in: &context)
            x += step
        }

        var y = floor(minY / step) * step
        while y <= maxY {
            let start = worldToScreen(Vector2(minX, y), size: size)
            let end = worldToScreen(Vector2(maxX, y), size: size)
            drawViewportLine(from: start, to: end, lineWidth: lineWidth, color: color, in: &context)
            y += step
        }
    }

    func drawViewportMarker(
        at point: Point,
        radius: Float,
        color: Color,
        in context: inout UIGraphicsContext
    ) {
        let diameter = radius * 2
        context.drawRect(
            Rect(x: point.x - radius, y: point.y - radius, width: diameter, height: diameter),
            color: color.opacity(0.18)
        )
        context.drawRect(
            Rect(x: point.x - radius, y: point.y - 1, width: diameter, height: 2),
            color: color
        )
        context.drawRect(
            Rect(x: point.x - 1, y: point.y - radius, width: 2, height: diameter),
            color: color
        )
    }

    func drawViewportLine(
        from start: Vector2,
        to end: Vector2,
        lineWidth: Float,
        color: Color,
        in context: inout UIGraphicsContext
    ) {
        if abs(start.x - end.x) <= 0.001 {
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            context.drawRect(
                Rect(x: start.x - lineWidth * 0.5, y: minY, width: lineWidth, height: max(1, maxY - minY)),
                color: color
            )
            return
        }

        if abs(start.y - end.y) <= 0.001 {
            let minX = min(start.x, end.x)
            let maxX = max(start.x, end.x)
            context.drawRect(
                Rect(x: minX, y: start.y - lineWidth * 0.5, width: max(1, maxX - minX), height: lineWidth),
                color: color
            )
            return
        }

        context.drawLine(start: start, end: end, lineWidth: lineWidth, color: color)
    }

    func draw3DGrid(in context: inout UIGraphicsContext, size: Size, theme: Theme, opacity: Float = 1) {
        let step: Float = 1
        let majorEvery = 5
        let extent = max(40, min(240, threeDPosition.length * 5))
        let centerX = floor(threeDPosition.x / step) * step
        let centerZ = floor(threeDPosition.z / step) * step
        let minX = centerX - extent
        let maxX = centerX + extent
        let minZ = centerZ - extent
        let maxZ = centerZ + extent

        var index = Int(floor(minX / step))
        var x = Float(index) * step
        while x <= maxX {
            let isAxis = abs(x) < 0.0001
            let isMajor = index.isMultiple(of: majorEvery)
            let color =
                isAxis
                ? theme.editorColors.purple.opacity(0.65 * opacity)
                : theme.editorColors.border.opacity((isMajor ? 0.40 : 0.22) * opacity)
            let width: Float = isAxis ? 2 : 1
            drawProjectedSegment(
                from: Vector3(x, 0, minZ),
                to: Vector3(x, 0, maxZ),
                in: &context,
                size: size,
                lineWidth: width,
                color: color
            )
            index += 1
            x += step
        }

        index = Int(floor(minZ / step))
        var z = Float(index) * step
        while z <= maxZ {
            let isAxis = abs(z) < 0.0001
            let isMajor = index.isMultiple(of: majorEvery)
            let color =
                isAxis
                ? theme.editorColors.blue.opacity(0.70 * opacity)
                : theme.editorColors.border.opacity((isMajor ? 0.40 : 0.22) * opacity)
            let width: Float = isAxis ? 2 : 1
            drawProjectedSegment(
                from: Vector3(minX, 0, z),
                to: Vector3(maxX, 0, z),
                in: &context,
                size: size,
                lineWidth: width,
                color: color
            )
            index += 1
            z += step
        }
    }

    func drawProjectedSegment(
        from start: Vector3,
        to end: Vector3,
        in context: inout UIGraphicsContext,
        size: Size,
        lineWidth: Float,
        color: Color
    ) {
        guard
            let segment = clipSegmentToNearPlane(start: start, end: end, size: size),
            let projectedStart = project(segment.start, size: size),
            let projectedEnd = project(segment.end, size: size)
        else {
            return
        }

        // Projection returns screen coordinates (Y down). Raw UI lines use Y up,
        // unlike drawRect, which performs this conversion in Rect.toTransform3D.
        context.drawLine(
            start: Vector2(projectedStart.x, -projectedStart.y),
            end: Vector2(projectedEnd.x, -projectedEnd.y),
            lineWidth: lineWidth,
            color: color
        )
    }

    func project(_ worldPoint: Vector3, size: Size) -> Vector2? {
        let state = cameraState(for: size)
        let viewProjection = state.projection.makeClipView() * state.transform.matrix.inverse
        let clipPoint = viewProjection * Vector4(worldPoint, 1)
        guard clipPoint.w.isFinite, abs(clipPoint.w) > 0.0001 else {
            return nil
        }
        let ndc = clipPoint.xyz / clipPoint.w
        guard
            ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite,
            ndc.z >= 0, ndc.z <= 1
        else {
            return nil
        }

        return Vector2(
            size.width * (ndc.x + 1) * 0.5,
            size.height * (1 - ndc.y) * 0.5
        )
    }

    func clipSegmentToNearPlane(start: Vector3, end: Vector3, size: Size) -> (start: Vector3, end: Vector3)? {
        let cameraState = cameraState(for: size)
        let near: Float = Swift.max(0.001, cameraState.projection.near + 0.001)
        let viewMatrix = cameraState.transform.matrix.inverse
        let startDepth = (viewMatrix * Vector4(start, 1)).z
        let endDepth = (viewMatrix * Vector4(end, 1)).z

        if startDepth <= near && endDepth <= near {
            return nil
        }

        var clippedStart = start
        var clippedEnd = end
        if startDepth <= near || endDepth <= near {
            let denominator = endDepth - startDepth
            guard abs(denominator) > 0.0001 else {
                return nil
            }
            let t = (near - startDepth) / denominator
            let clipped = start + (end - start) * t
            if startDepth <= near {
                clippedStart = clipped
            } else {
                clippedEnd = clipped
            }
        }

        return (clippedStart, clippedEnd)
    }

    func coordinateRuler(in size: Size) -> EditorSceneViewportCoordinateRuler {
        let opacity = 1 - smoothPerspectiveBlend
        guard opacity > 0.001, size.width > 0, size.height > 0 else {
            return EditorSceneViewportCoordinateRuler(opacity: 0, labels: [])
        }

        let safeZoom = max(0.001, twoDZoom)
        let step = niceGridStep(minPixels: 72, zoom: safeZoom)
        let halfWidth = size.width * 0.5 / safeZoom
        let halfHeight = size.height * 0.5 / safeZoom
        let minX = twoDCenter.x - halfWidth
        let maxX = twoDCenter.x + halfWidth
        let minY = twoDCenter.y - halfHeight
        let maxY = twoDCenter.y + halfHeight
        var labels: [EditorSceneViewportCoordinateRuler.Label] = []

        var x = floor(minX / step) * step
        while x <= maxX {
            let screenX = worldToScreen(Vector2(x, 0), size: size).x
            if screenX >= 44 && screenX <= size.width - 4 {
                labels.append(
                    EditorSceneViewportCoordinateRuler.Label(
                        axis: .x,
                        value: x,
                        position: Point(x: screenX, y: 0),
                        text: formatted(x)
                    )
                )
            }
            x += step
        }

        var y = floor(minY / step) * step
        while y <= maxY {
            let screenY = worldToScreen(Vector2(0, y), size: size).y
            if screenY >= 24 && screenY <= size.height - 4 {
                labels.append(
                    EditorSceneViewportCoordinateRuler.Label(
                        axis: .y,
                        value: y,
                        position: Point(x: 0, y: screenY),
                        text: formatted(y)
                    )
                )
            }
            y += step
        }

        return EditorSceneViewportCoordinateRuler(opacity: opacity, labels: labels)
    }

    func worldToScreen(_ point: Vector2, size: Size) -> Vector2 {
        Vector2(
            (point.x - twoDCenter.x) * twoDZoom + size.width * 0.5,
            size.height * 0.5 - (point.y - twoDCenter.y) * twoDZoom
        )
    }

    func niceGridStep(minPixels: Float, zoom: Float) -> Float {
        let rawStep = max(0.0001, minPixels / zoom)
        let exponent = floor(log10(rawStep))
        let magnitude = pow(Float(10), exponent)
        let normalized = rawStep / magnitude

        if normalized <= 1 {
            return magnitude
        } else if normalized <= 2 {
            return 2 * magnitude
        } else if normalized <= 5 {
            return 5 * magnitude
        } else {
            return 10 * magnitude
        }
    }

    func formatted(_ value: Float) -> String {
        EditorSceneModelFormatting.format(Double(value))
    }
}
