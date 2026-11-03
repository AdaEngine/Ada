import Foundation
import Math

/// A repeatable twelve-second flight through the upper gallery.
public enum SponzaLightMotion {
    public static func position(seconds: Double) -> Vector3 {
        let phase: Double = (seconds.isFinite ? seconds : 0).remainder(dividingBy: 12) * .pi / 6
        let x = Float(8 * Foundation.sin(phase))
        let y = Float(7.4 + 0.6 * Foundation.sin(2 * phase))
        let z = Float(5.35 + 0.5 * Foundation.cos(phase))
        return Vector3(x, y, z)
    }
}
