import AdaGeometry
import Foundation
import Math

/// Solid shapes use a unit bounding box, centered on the origin.
public enum CSGShape: String, Codable, CaseIterable, Sendable {
    case box, sphere, cylinder

    private static let segments = 32
    private static let sphereRings = 16

    func surface(source: UInt32) throws -> TriangleSurface {
        let solid = try closedSurface(source: source)
        var positions: [Vector3] = []
        var coordinates: [Vector2] = []
        positions.reserveCapacity(solid.indices.count)
        coordinates.reserveCapacity(solid.indices.count)
        for start in stride(from: 0, to: solid.indices.count, by: 3) {
            let points = (start..<(start + 3)).map { solid.positions[Int(solid.indices[$0])] }
            positions.append(contentsOf: points)
            coordinates.append(contentsOf: uv(for: points))
        }
        // The kernel welds these shared positions without merging distinct UV attributes.
        return TriangleSurface(
            positions: positions,
            indices: positions.indices.map { UInt32($0) },
            textureCoordinates: coordinates,
            faceSources: solid.faceSources,
            faceIDs: solid.faceIDs
        )
    }

    private func closedSurface(source: UInt32) throws -> TriangleSurface {
        let profile: [Vector2]
        switch self {
        case .box: return try .box(minimum: Vector3(-0.5), maximum: Vector3(0.5), source: source)
        case .sphere:
            profile = (1..<Self.sphereRings).map { ring in
                let angle = Double.pi * Double(ring) / Double(Self.sphereRings)
                return Vector2(Float(Foundation.sin(angle) / 2), Float(Foundation.cos(angle) / 2))
            }
        case .cylinder:
            profile = [[0.5, 0.5], [0.5, -0.5]]
        }

        // The Boolean input shares a single vertex at each pole and around the seam.
        let count = Self.segments
        let rings = profile.flatMap { circle(radius: $0.x, height: $0.y) }
        let north = UInt32(rings.count)
        let south = north + 1
        let positions = rings + [[0, 0.5, 0], [0, -0.5, 0]]
        var indices: [UInt32] = []
        for segment in 0..<count {
            let next = (segment + 1) % count
            indices += [north, UInt32(next), UInt32(segment)]
            for row in 0..<(profile.count - 1) {
                let a = UInt32(row * count + segment)
                let b = UInt32((row + 1) * count + segment)
                let c = UInt32((row + 1) * count + next)
                let d = UInt32(row * count + next)
                indices += [a, d, c, a, c, b]
            }
            let end = (profile.count - 1) * count
            indices += [south, UInt32(end + segment), UInt32(end + next)]
        }
        let faceCount = indices.count / 3
        return TriangleSurface(
            positions: positions,
            indices: indices,
            faceSources: Array(repeating: source, count: faceCount),
            faceIDs: Array(0..<UInt32(faceCount))
        )
    }

    /// Closed local-space loops for the selected operand overlay.
    public func outlineLoops() -> [[Vector3]] {
        switch self {
        case .box:
            let lower: [Vector3] = [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]]
            let upper = lower.map { Vector3($0.x, 0.5, $0.z) }
            return [lower, upper] + zip(lower, upper).map { a, b in [a, b] }
        case .sphere:
            let equator = circle(radius: 0.5, height: 0)
            return [equator, equator.map { [$0.x, $0.z, 0] }, equator.map { [0, $0.x, $0.z] }]
        case .cylinder:
            let lower = circle(radius: 0.5, height: -0.5)
            let upper = lower.map { Vector3($0.x, 0.5, $0.z) }
            let sides = stride(from: 0, to: Self.segments, by: Self.segments / 4).map { [lower[$0], upper[$0]] }
            return [lower, upper] + sides
        }
    }

    private func circle(radius: Float, height: Float) -> [Vector3] {
        (0..<Self.segments).map { segment in
            let angle = 2 * Double.pi * Double(segment) / Double(Self.segments)
            return Vector3(radius * Float(Foundation.cos(angle)), height, radius * Float(Foundation.sin(angle)))
        }
    }

    private func uv(for points: [Vector3]) -> [Vector2] {
        let normal = (points[1] - points[0]).cross(points[2] - points[0])
        if self == .sphere || (self == .cylinder && abs(normal.y) < max(abs(normal.x), abs(normal.z))) {
            return angularUV(for: points)
        }
        let axis = Vector3(abs(normal.x), abs(normal.y), abs(normal.z))
        if axis.y >= max(axis.x, axis.z) {
            return points.map { [$0.x + 0.5, $0.z + 0.5] }
        }
        if axis.x >= axis.z {
            return points.map { [$0.z + 0.5, 0.5 - $0.y] }
        }
        return points.map { [$0.x + 0.5, 0.5 - $0.y] }
    }

    private func angularUV(for points: [Vector3]) -> [Vector2] {
        let angles: [Float?] = points.map { point in
            let radius = point.x * point.x + point.z * point.z
            return radius < 1e-12 ? nil : Math.atan2(point.z, point.x) / (2 * .pi) + 0.5
        }
        let anchor = angles.compactMap { $0 }.first ?? 0.5
        let unwrapped = angles.map { angle in angle.map { $0 - ($0 - anchor).rounded() } }
        let valid = unwrapped.compactMap { $0 }
        let pole = valid.reduce(0, +) / Float(max(valid.count, 1))
        return zip(points, unwrapped).map { point, longitude in
            let elevation = Double(max(-1, min(1, point.y * 2)))
            let latitude = self == .sphere ? Float(Foundation.acos(elevation) / Double.pi) : 0.5 - point.y
            return [longitude ?? pole, latitude]
        }
    }
}
