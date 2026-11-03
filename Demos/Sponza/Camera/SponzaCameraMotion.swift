import AdaTransform
import Foundation

/// Repeatable six-second gallery controls, evaluated from wall time rather than frame count.
public enum SponzaCameraMotion: String, CaseIterable, Sendable {
    case stationary
    case translation
    case rotation

    public func pose(from origin: Transform, seconds: Double) -> Transform {
        guard seconds.isFinite else { return origin }
        let phase = seconds.remainder(dividingBy: 6) * .pi / 3
        var pose = origin
        switch self {
        case .stationary:
            break
        case .translation:
            // The upper gallery runs along world X. Keep height, heading and corridor Z fixed.
            pose.position.x += Float(1.5 * (1 - cos(phase)))
        case .rotation:
            var camera = SponzaFlyCamera()
            camera.setPose(origin)
            pose.rotation = SponzaFlyCamera.rotation(
                yaw: camera.yaw + Float(phase),
                pitch: camera.pitch + Float(0.2 * sin(2 * phase))
            )
        }
        return pose
    }
}
