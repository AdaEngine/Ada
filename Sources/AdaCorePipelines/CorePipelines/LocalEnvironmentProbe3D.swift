import Math

/// A static environment capture. Box projection corrects specular parallax inside its world-space bounds.
/// Diffuse irradiance remains a single capture; it does not provide dynamic visibility or spatial GI.
public struct LocalEnvironmentProbe3D: Codable, Sendable, Equatable {
    public var capturePosition: Vector3
    public var minimum: Vector3
    public var maximum: Vector3

    public init(capturePosition: Vector3, minimum: Vector3, maximum: Vector3) {
        self.capturePosition = capturePosition
        self.minimum = minimum
        self.maximum = maximum
    }

    public var isValid: Bool {
        return LocalLighting3DMath.isFinite(capturePosition) && LocalLighting3DMath.isFinite(minimum) && LocalLighting3DMath.isFinite(maximum)
            && minimum.x < maximum.x && minimum.y < maximum.y && minimum.z < maximum.z
            && contains(capturePosition)
    }

    private func contains(_ position: Vector3) -> Bool {
        position.x >= minimum.x && position.x <= maximum.x && position.y >= minimum.y && position.y <= maximum.y
            && position.z >= minimum.z && position.z <= maximum.z
    }

    /// CPU reference for the shader's ray/box exit. Outside the volume, keep the original infinite-environment direction.
    public func projectedDirection(position: Vector3, direction: Vector3) -> Vector3 {
        guard isValid, contains(position), direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
              direction.squaredLength > 0.000001 else { return direction }
        func exit(_ p: Float, _ d: Float, _ low: Float, _ high: Float) -> Float {
            abs(d) < 0.000001 ? Float.greatestFiniteMagnitude : ((d > 0 ? high : low) - p) / d
        }
        let travel = min(exit(position.x, direction.x, minimum.x, maximum.x),
                         exit(position.y, direction.y, minimum.y, maximum.y), exit(position.z, direction.z, minimum.z, maximum.z))
        let projected = position + direction * travel - capturePosition
        return projected.squaredLength > 0.000001 ? projected.normalized : direction
    }
}
