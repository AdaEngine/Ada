import AdaECS
import Foundation
import Math

/// Stable surfaces of a book-style foldable. Coordinates are local to each leaf.
public enum FoldSurface: String, Codable, Sendable, CaseIterable {
    case innerLeft, innerRight, outer
}

/// An explicitly supplied pose, independent of window size. 180 degrees is flat.
public struct FoldPose: Resource, Codable, Equatable, Sendable {
    public var angle: Float
    public var showsOuter: Bool
    public var playableAngle: Float { angle.isFinite ? min(180, max(45, angle)) : 180 }

    public init(angle: Float = 180, showsOuter: Bool = false) {
        self.angle = angle
        self.showsOuter = showsOuter
    }

    public func worldPoint(_ point: Vector3, surface: FoldSurface, width: Float = 400) -> Vector3 {
        guard surface != .innerLeft else { return point }
        let radians = (180 - playableAngle) * .pi / 180
        let p = surface == .outer ? Vector3(width - point.x, point.y, -point.z) : point
        return Vector3(width + Math.cos(radians) * p.x - Math.sin(radians) * p.z, p.y, Math.sin(radians) * p.x + Math.cos(radians) * p.z)
    }

    public func localPoint(_ point: Vector3, surface: FoldSurface, width: Float = 400) -> Vector3 {
        guard surface != .innerLeft else { return point }
        let radians = (180 - playableAngle) * .pi / 180
        let x = point.x - width
        let p = Vector3(Math.cos(radians) * x + Math.sin(radians) * point.z, point.y, -Math.sin(radians) * x + Math.cos(radians) * point.z)
        return surface == .outer ? Vector3(width - p.x, p.y, -p.z) : p
    }

    /// Projects a ray beyond an occluder onto a leaf. Degenerate/behind-light intersections have no shadow.
    public func project(light: Vector3, point: Vector3, onto surface: FoldSurface) -> Vector2? {
        let origin = localPoint(light, surface: surface)
        let caster = localPoint(point, surface: surface)
        let denominator = caster.z - origin.z
        guard abs(denominator) > 0.0001 else { return nil }
        let t = -origin.z / denominator
        guard t >= 1, t.isFinite else { return nil }
        let result = Vector2(origin.x + (caster.x - origin.x) * t, origin.y + (caster.y - origin.y) * t)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    @MainActor public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(Self.self, names: ["FoldPose"])
        RuntimeResourceReflectionRegistry.register(Self.self, fields: ["angle", "showsOuter"].map { key in
            unsafe ReflectedComponentField(
                key: key, label: key, kind: .readOnly, isWritable: false, accepts: { _ in false },
                read: { _ in nil }, write: { _, _ in nil }, readPointer: { pointer in
                    let pose = unsafe pointer.assumingMemoryBound(to: Self.self).pointee
                    return key == "angle" ? .double(Double(pose.playableAngle)) : .bool(pose.showsOuter)
                }
            )
        })
    }
}

/// Local placement of a scene object on an internal or external display surface.
@Component
public struct FoldAttachment: Codable, Sendable {
    public var surface: FoldSurface
    public var position: Vector3
    public init(surface: FoldSurface = .innerLeft, position: Vector3 = .zero) {
        self.surface = surface
        self.position = position
    }
}
