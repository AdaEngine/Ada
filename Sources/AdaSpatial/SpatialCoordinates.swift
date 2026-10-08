import Math

/// Coordinate conversion between ARKit's right-handed world and Ada's +Z-forward world.
public enum SpatialCoordinates {
    private static let flipZ = Transform3D(scale: [1, 1, -1])

    public static func fromApple(_ point: Vector3) -> Vector3 {
        [point.x, point.y, -point.z]
    }

    /// Converts both the world and local basis, preserving a proper rotation.
    public static func fromApple(_ pose: Transform3D) -> Transform3D {
        flipZ * pose * flipZ
    }

    /// Converts a native Compositor Services projection (`rightUpBack`) to Ada view space.
    /// The compositor convention controls NDC winding; its input is still right-handed
    /// view space. Mirror the input Z axis explicitly before converting reverse depth.
    public static func fromAppleProjection(_ projection: Transform3D) -> Transform3D {
        forwardDepthProjection(projection * flipZ)
    }

    /// Compositor projections use reverse Z. Ada's existing pipelines use forward Z.
    /// This changes only the depth convention, not the view-space handedness.
    public static func forwardDepthProjection(_ reverseZ: Transform3D) -> Transform3D {
        var projection = reverseZ
        for column in 0..<4 {
            projection[column, 2] = reverseZ[column, 3] - reverseZ[column, 2]
        }
        return projection
    }
}
