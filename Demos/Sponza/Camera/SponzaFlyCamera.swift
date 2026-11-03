import AdaTransform
import Foundation
import Math

/// +Z forward, yaw about world Y, then pitch about the camera's local X. No roll.
public struct SponzaFlyCamera {
    public private(set) var transform = Transform()
    public private(set) var yaw: Float = 0
    public private(set) var pitch: Float = 0

    public init() {}

    public mutating func setPose(_ pose: Transform) {
        transform = pose
        let forward = pose.matrix.z
        yaw = Math.atan2(forward.x, forward.z)
        pitch = -asin(max(-1, min(1, forward.y)))
    }

    public static func rotation(yaw: Float, pitch: Float) -> Quat {
        let horizontal = Quat(axis: [0, 1, 0], angle: yaw)
        let vertical = Quat(axis: [1, 0, 0], angle: pitch)
        // Hamilton product Y * X; spelling out the axes avoids legacy Euler conventions.
        return Quat(x: horizontal.w * vertical.x, y: horizontal.y * vertical.w,
            z: -horizontal.y * vertical.x, w: horizontal.w * vertical.w).normalized
    }

    public static func looking(from position: Vector3, at target: Vector3) -> Transform {
        let direction = (target - position).normalized
        return Transform(rotation: rotation(yaw: Math.atan2(direction.x, direction.z), pitch: -asin(max(-1, min(1, direction.y)))), position: position)
    }

    public mutating func look(delta: Vector2) {
        guard delta.x.isFinite, delta.y.isFinite, delta != .zero else { return }
        yaw = (yaw + delta.x * 0.003).remainder(dividingBy: 2 * .pi)
        pitch = max(-1.55, min(1.55, pitch + delta.y * 0.003))
        transform.rotation = Self.rotation(yaw: yaw, pitch: pitch)
    }

    public mutating func move(local: Vector3, seconds: Double, fast: Bool) {
        guard seconds.isFinite, seconds > 0 else { return }
        let basis = transform.matrix
        var direction = Vector3(basis.x.x, basis.x.y, basis.x.z) * local.x
            + Vector3(0, local.y, 0) + Vector3(basis.z.x, basis.z.y, basis.z.z) * local.z
        if direction.length > 1 { direction = direction.normalized }
        transform.position += direction * Float(min(seconds, 0.05)) * (fast ? 10 : 3)
    }
}
