import Foundation
import Math

struct ShadowCascade3D: Sendable {
    var viewProjection: Transform3D
    var farDepth: Float
    var radius: Float
    var corners: [Vector3]
}

extension DirectionalShadow3DMath {
    /// Fits orientation-independent bounding spheres to frustum slices, then snaps XY to texel centers.
    static func cascades(
        view: Transform3D,
        projection: Transform3D,
        near: Float,
        far: Float,
        directionToLight: Vector3,
        count: Int,
        lambda: Float,
        blendFraction: Float = 0.1,
        resolution: Int = DirectionalShadow3D.resolution
    ) -> [ShadowCascade3D] {
        let count = min(max(count, 1), 3)
        let near = finiteRenderValue(near, fallback: 0.1, range: 0.01...100)
        let far = max(near + 0.1, finiteRenderValue(far, fallback: 30, range: 0.1...1000))
        let lambda = finiteRenderValue(lambda, fallback: 0.65, range: 0...1)
        let inverseProjection = projection.inverse
        let inverseView = view.inverse
        let direction = directionToLight.length > 0.001 ? -directionToLight.normalized : Vector3(0, -1, 0)
        let up: Vector3 = abs(direction.dot(.up)) > 0.95 ? .right : .up
        let right = up.cross(direction).normalized
        let viewUp = direction.cross(right)
        var result: [ShadowCascade3D] = []
        var sliceNear = near
        var overlap: Float = 0
        for index in 0..<count {
            let fraction = Float(index + 1) / Float(count)
            let logarithmic = near * Float(pow(Double(far / near), Double(fraction)))
            let sliceFar = lambda * logarithmic + (1 - lambda) * (near + (far - near) * fraction)
            var corners: [Vector3] = []
            for y: Float in [-1, 1] {
                for x: Float in [-1, 1] {
                    let front = inverseProjection * Vector4(x, y, 0, 1)
                    let back = inverseProjection * Vector4(x, y, 1, 1)
                    let a = front.xyz / front.w
                    let b = back.xyz / back.w
                    let dz = b.z - a.z
                    for depth in [max(near, sliceNear - overlap), sliceFar] {
                        let point = a + (b - a) * ((depth - a.z) / dz)
                        corners.append((inverseView * Vector4(point, 1)).xyz)
                    }
                }
            }
            var center = Vector3.zero
            for corner in corners { center += corner }
            center /= Float(corners.count)
            // Rounding up prevents the projection scale from changing under tiny camera rotations.
            let rawRadius = corners.map { ($0 - center).length }.max() ?? 1
            let radius: Float = (rawRadius * 16).rounded(.up) / 16 + 0.125
            let texel = radius * 2 / Float(max(resolution, 1))
            let snapped = center + right * ((center.dot(right) / texel).rounded() * texel - center.dot(right))
                + viewUp * ((center.dot(viewUp) / texel).rounded() * texel - center.dot(viewUp))
            let eye = snapped - direction * (radius + far)
            let lightView = Transform3D(
                [right.x, viewUp.x, direction.x, 0],
                [right.y, viewUp.y, direction.y, 0],
                [right.z, viewUp.z, direction.z, 0],
                [-right.dot(eye), -viewUp.dot(eye), -direction.dot(eye), 1]
            )
            let lightProjection = Transform3D.orthographic(left: -radius, right: radius, top: radius, bottom: -radius, zNear: 0.1, zFar: (radius + far) * 2)
            result.append(ShadowCascade3D(viewProjection: lightProjection * lightView, farDepth: sliceFar, radius: radius, corners: corners))
            overlap = (sliceFar - sliceNear) * finiteRenderValue(blendFraction, fallback: 0.1, range: 0...0.25)
            sliceNear = sliceFar
        }
        return result
    }
}
