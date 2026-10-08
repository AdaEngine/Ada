@_spi(AdaEngine) import AdaEngine
import Math

/// Screen geometry and drag math shared by drawing and hit testing.
struct EditorTransformGizmo {
    enum Handle: Int, CaseIterable {
        case x, y, z, center
        var axis: Vector3 {
            switch self {
            case .x: Vector3(1, 0, 0)
            case .y: Vector3(0, 1, 0)
            case .z: Vector3(0, 0, 1)
            case .center: .zero
            }
        }
        var color: Color {
            switch self {
            case .x: Color(red: 0.96, green: 0.32, blue: 0.34)
            case .y: Color(red: 0.36, green: 0.84, blue: 0.46)
            case .z: Color(red: 0.30, green: 0.60, blue: 1)
            case .center: .white
            }
        }
        var planeAxes: (Vector3, Vector3) {
            switch self {
            case .x: (.init(0, 1, 0), .init(0, 0, 1))
            case .y: (.init(0, 0, 1), .init(1, 0, 0))
            default: (.init(1, 0, 0), .init(0, 1, 0))
            }
        }
    }

    struct Shape {
        let handle: Handle
        let points: [Vector2]
    }

    let tool: EditorSceneViewportTool
    let origin: Vector3
    let screenOrigin: Vector2
    let parentMatrix: Transform3D
    let basis: Transform3D
    let viewProjection: Transform3D
    let size: Size
    let worldLength: Float
    let depth: Float
    let shapes: [Shape]

    init?(tool: EditorSceneViewportTool, transform: Transform, parent: Transform3D, camera: EditorSceneViewportModel.CameraState, size: Size, is2D: Bool) {
        guard tool != .select, size.width > 0, size.height > 0, abs(parent.determinant) > 0.000001 else {
            return nil
        }
        self.tool = tool
        self.parentMatrix = parent
        self.size = size
        origin = (parent * Vector4(transform.position, 1)).xyz
        viewProjection = camera.projection.makeClipView() * camera.transform.matrix.inverse
        let clip = viewProjection * Vector4(origin, 1)
        guard clip.w > 0.00001 else {
            return nil
        }
        depth = clip.z / clip.w
        guard let projected = Self.project(origin, matrix: viewProjection, size: size) else {
            return nil
        }
        screenOrigin = projected
        guard let neighbor = Self.unproject(projected + Vector2(1, 0), depth: depth, inverse: viewProjection.inverse, size: size) else {
            return nil
        }
        worldLength = (neighbor - origin).length * 80
        guard worldLength.isFinite, worldLength > 0.000001 else {
            return nil
        }
        let orientation = tool == .translate ? Transform3D.identity : parent * Transform(rotation: transform.rotation).matrix
        basis = Transform3D(columns: [
            Vector4(orientation.x.xyz.normalized, 0), Vector4(orientation.y.xyz.normalized, 0),
            Vector4(orientation.z.xyz.normalized, 0), Vector4(origin, 1),
        ])
        let handles: [Handle] = is2D ? (tool == .rotate ? [.z] : [.x, .y]) : [.x, .y, .z]
        var shapes: [Shape] = []
        for handle in handles {
            if tool == .rotate {
                let (u, v) = handle.planeAxes
                var points: [Vector2] = []
                for index in 0...64 {
                    let angle = Float(index) * .pi * 2 / 64
                    let local = (u * Math.cos(angle) + v * Math.sin(angle)) * worldLength * 0.8
                    guard let point = Self.project((basis * Vector4(local, 1)).xyz, matrix: viewProjection, size: size) else {
                        break
                    }
                    points.append(point)
                }
                if points.count == 65 {
                    shapes.append(Shape(handle: handle, points: points))
                }
            } else {
                let direction = (basis * Vector4(handle.axis, 0)).xyz
                if let end = Self.project(origin + direction * worldLength, matrix: viewProjection, size: size), (end - projected).squaredLength > 256 {
                    let start = projected + (end - projected).normalized * 12
                    shapes.append(Shape(handle: handle, points: [start, end]))
                }
            }
        }
        self.shapes = shapes
    }

    func hitTest(_ point: Vector2) -> Handle? {
        if tool != .rotate, abs(point.x - screenOrigin.x) <= 8, abs(point.y - screenOrigin.y) <= 8 {
            return .center
        }
        var closest: (Handle, Float)?
        for shape in shapes {
            for (a, b) in zip(shape.points, shape.points.dropFirst()) {
                let segment = b - a
                let t = max(0, min(1, (point - a).dot(segment) / max(0.0001, segment.squaredLength)))
                let distance = (point - (a + segment * t)).squaredLength
                if distance <= 64, distance < (closest?.1 ?? .infinity) {
                    closest = (shape.handle, distance)
                }
            }
        }
        return closest?.0
    }

    @MainActor
    func draw(in context: inout UIGraphicsContext, highlighted: Handle?) {
        for shape in shapes {
            let color = shape.handle == highlighted ? Color.yellow : shape.handle.color
            var path = Path()
            if let first = shape.points.first {
                path.move(to: first)
            }
            for point in shape.points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .black.opacity(0.75), style: StrokeStyle(lineWidth: 5))
            context.stroke(path, with: color, style: StrokeStyle(lineWidth: 2.5))
            guard tool != .rotate, let end = shape.points.last, let start = shape.points.first else {
                continue
            }
            if tool == .translate {
                let direction = (end - start).normalized
                let normal = Vector2(-direction.y, direction.x)
                var arrow = Path()
                arrow.move(to: end + direction * 4)
                arrow.addLine(to: end - direction * 9 + normal * 5)
                arrow.addLine(to: end - direction * 9 - normal * 5)
                arrow.closeSubpath()
                context.fill(arrow, with: color)
            } else {
                context.drawRect(Rect(x: end.x - 5, y: end.y - 5, width: 10, height: 10), color: color)
            }
        }
        if tool != .rotate {
            let rect = Rect(x: screenOrigin.x - 6, y: screenOrigin.y - 6, width: 12, height: 12)
            context.fill(RectangleShape().path(in: rect), with: highlighted == .center ? .yellow : .white.opacity(0.9))
        }
    }

    func ray(at point: Vector2) -> Ray? {
        let inverse = viewProjection.inverse
        guard
            let near = Self.unproject(point, depth: 0, inverse: inverse, size: size),
            let far = Self.unproject(point, depth: 0.99, inverse: inverse, size: size)
        else {
            return nil
        }
        return Ray(origin: near, direction: (far - near).normalized)
    }

    func axisParameter(at point: Vector2, handle: Handle) -> Float? {
        guard let ray = ray(at: point) else {
            return nil
        }
        let axis = (basis * Vector4(handle.axis, 0)).xyz.normalized
        let b = ray.direction.dot(axis)
        let denominator = 1 - b * b
        guard denominator > 0.00001 else {
            return nil
        }
        let w = ray.origin - origin
        return (axis.dot(w) - b * ray.direction.dot(w)) / denominator
    }

    func rotationAngle(at point: Vector2, handle: Handle) -> Float? {
        guard let ray = ray(at: point) else {
            return nil
        }
        let inverse = basis.inverse
        let origin = (inverse * Vector4(ray.origin, 1)).xyz
        let direction = (inverse * Vector4(ray.direction, 0)).xyz
        let divisor = direction.dot(handle.axis)
        guard abs(divisor) > 0.00001 else {
            return nil
        }
        let local = origin + direction * (-origin.dot(handle.axis) / divisor)
        let (u, v) = handle.planeAxes
        guard local.squaredLength > 0.000001 else {
            return nil
        }
        return Math.atan2(local.dot(v), local.dot(u))
    }

    static func project(_ point: Vector3, matrix: Transform3D, size: Size) -> Vector2? {
        let clip = matrix * Vector4(point, 1)
        guard clip.w > 0.00001 else {
            return nil
        }
        let ndc = clip.xyz / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z >= 0, ndc.z <= 1 else {
            return nil
        }
        return Vector2((ndc.x + 1) * size.width / 2, (1 - ndc.y) * size.height / 2)
    }

    static func unproject(_ point: Vector2, depth: Float, inverse: Transform3D, size: Size) -> Vector3? {
        let world = inverse * Vector4(point.x * 2 / size.width - 1, 1 - point.y * 2 / size.height, depth, 1)
        guard abs(world.w) > 0.000001 else {
            return nil
        }
        let value = world.xyz / world.w
        return value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : nil
    }
}

extension EditorTransformGizmo {
    struct Drag {
        let gizmo: EditorTransformGizmo
        let handle: Handle
        let start: Vector2
        let transform: Transform
        var lastAngle: Float?
        var accumulatedAngle: Float = 0

        init(gizmo: EditorTransformGizmo, handle: Handle, start: Vector2, transform: Transform) {
            self.gizmo = gizmo
            self.handle = handle
            self.start = start
            self.transform = transform
            self.lastAngle = gizmo.rotationAngle(at: start, handle: handle)
        }

        mutating func updated(at point: Vector2) -> Transform {
            var result = transform
            if point == start, accumulatedAngle == 0 {
                return result
            }
            let delta = point - start
            switch gizmo.tool {
            case .select: break
            case .translate:
                let worldDelta: Vector3
                if handle == .center {
                    guard
                        let a = EditorTransformGizmo.unproject(start, depth: gizmo.depth, inverse: gizmo.viewProjection.inverse, size: gizmo.size),
                        let b = EditorTransformGizmo.unproject(point, depth: gizmo.depth, inverse: gizmo.viewProjection.inverse, size: gizmo.size)
                    else {
                        return result
                    }
                    worldDelta = b - a
                } else {
                    guard let a = gizmo.axisParameter(at: start, handle: handle), let b = gizmo.axisParameter(at: point, handle: handle) else {
                        return result
                    }
                    worldDelta = handle.axis * (b - a)
                }
                result.position += (gizmo.parentMatrix.inverse * Vector4(worldDelta, 0)).xyz
            case .scale:
                let factor: Float
                if handle == .center {
                    factor = max(0.01, 1 + (delta.x - delta.y) / 120)
                    result.scale = transform.scale * factor
                } else {
                    guard let a = gizmo.axisParameter(at: start, handle: handle), let b = gizmo.axisParameter(at: point, handle: handle) else {
                        return result
                    }
                    factor = max(0.01, 1 + (b - a) / gizmo.worldLength)
                    result.scale[handle.rawValue] *= factor
                }
            case .rotate:
                if let angle = gizmo.rotationAngle(at: point, handle: handle), let lastAngle {
                    let difference = angle - lastAngle
                    accumulatedAngle += Math.atan2(Math.sin(difference), Math.cos(difference))
                    self.lastAngle = angle
                } else {
                    accumulatedAngle = (delta.x - delta.y) / 80
                }
                let rotation = Quat(axis: handle.axis, angle: accumulatedAngle)
                result.rotation = Self.compose(transform.rotation, rotation).normalized
            }
            return result
        }

        private static func compose(_ a: Quat, _ b: Quat) -> Quat {
            Quat(
                x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
            )
        }
    }
}
