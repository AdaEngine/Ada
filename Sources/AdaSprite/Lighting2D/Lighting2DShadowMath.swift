//
//  Lighting2DShadowMath.swift
//  AdaEngine
//

import Math

/// Builds shadow-fin quads for a point light against a CCW polygon in world space.
public enum Lighting2DShadowMath {
    public static let extrudeDistance: Float = 16_000

    @inline(__always)
    private static func unit(from origin: Vector2, toward point: Vector2) -> Vector2 {
        let v = point - origin
        let s = v.x * v.x + v.y * v.y
        if s < Float.ulpOfOne {
            return .zero
        }
        let inv = 1 / sqrt(s)
        return Vector2(v.x * inv, v.y * inv)
    }

    /// Returns quad corners in order suitable for two triangles: (q0,q1,q2), (q0,q2,q3).
    public static func shadowFinQuads(
        lightWorld: Vector2,
        polygonWorldCCW: [Vector2]
    ) -> [Vector2] {
        guard polygonWorldCCW.count >= 2 else {
            return []
        }
        var output: [Vector2] = []
        output.reserveCapacity(polygonWorldCCW.count * 6)
        let n = polygonWorldCCW.count
        for index in 0..<n {
            let a = polygonWorldCCW[index]
            let b = polygonWorldCCW[(index + 1) % n]
            let edge = b - a
            let toLight = lightWorld - a
            let crossZ = edge.x * toLight.y - edge.y * toLight.x
            // CCW polygon: interior is to the left of each edge; extrude only when the light is strictly on the exterior (right).
            if crossZ >= 0 {
                continue
            }
            let dirA = unit(from: lightWorld, toward: a)
            let dirB = unit(from: lightWorld, toward: b)
            let aFar = a + dirA * extrudeDistance
            let bFar = b + dirB * extrudeDistance
            output.append(contentsOf: [a, b, bFar, a, bFar, aFar])
        }
        return output
    }

    /// Directional shadow fins: extrude each silhouette edge along ``lightDirection`` (world).
    public static func directionalShadowFinQuads(
        polygonWorldCCW: [Vector2],
        lightDirection: Vector2
    ) -> [Vector2] {
        guard polygonWorldCCW.count >= 2 else {
            return []
        }
        let dir: Vector2 = {
            let s = lightDirection.x * lightDirection.x + lightDirection.y * lightDirection.y
            if s < Float.ulpOfOne {
                return Vector2(0, -1)
            }
            let inv = 1 / sqrt(s)
            return Vector2(lightDirection.x * inv, lightDirection.y * inv)
        }()
        var output: [Vector2] = []
        output.reserveCapacity(polygonWorldCCW.count * 6)
        let n = polygonWorldCCW.count
        for index in 0..<n {
            let a = polygonWorldCCW[index]
            let b = polygonWorldCCW[(index + 1) % n]
            let edge = b - a
            let crossZ = edge.x * dir.y - edge.y * dir.x
            if crossZ >= 0 {
                continue
            }
            let aFar = a + dir * extrudeDistance
            let bFar = b + dir * extrudeDistance
            output.append(contentsOf: [a, b, bFar, a, bFar, aFar])
        }
        return output
    }
}
