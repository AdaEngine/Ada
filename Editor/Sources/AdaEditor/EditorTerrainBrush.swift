@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

enum EditorTerrainBrushMode: String, CaseIterable {
    case raise = "Raise Ground"
    case lower = "Lower Ground"
    case smooth = "Smooth Ground"
    case flatten = "Flatten Ground"
}

enum EditorTerrainBrush {
    /// Strength is height units per second; smoothing converges without overshooting.
    static func apply(to terrain: inout Terrain3D, at point: Vector3, mode: EditorTerrainBrushMode,
                      radius: Float, strength: Float, duration: Float, flattenHeight: Float) {
        guard radius.isFinite, radius > 0, strength.isFinite, strength > 0,
              duration.isFinite, duration > 0, point.x.isFinite, point.z.isFinite,
              flattenHeight.isFinite, (try? terrain.validate()) != nil else { return }
        let original = terrain.heights
        let step = terrain.size / Float(terrain.resolution - 1)
        for z in 0..<terrain.resolution {
            for x in 0..<terrain.resolution {
                let dx = Float(x) * step - terrain.size / 2 - point.x
                let dz = Float(z) * step - terrain.size / 2 - point.z
                let distance = Math.sqrt(dx * dx + dz * dz) / radius
                guard distance < 1 else { continue }
                let falloff = (1 - distance * distance) * (1 - distance * distance)
                let amount = strength * min(duration, 0.1) * falloff
                let index = z * terrain.resolution + x
                switch mode {
                case .raise: terrain.heights[index] += amount
                case .lower: terrain.heights[index] -= amount
                case .flatten:
                    terrain.heights[index] += (flattenHeight - original[index]) * min(1, amount)
                case .smooth:
                    var total: Float = 0
                    var count: Float = 0
                    for nz in max(0, z - 1)...min(terrain.resolution - 1, z + 1) {
                        for nx in max(0, x - 1)...min(terrain.resolution - 1, x + 1) {
                            total += original[nz * terrain.resolution + nx]
                            count += 1
                        }
                    }
                    terrain.heights[index] += (total / count - original[index]) * min(1, amount)
                }
            }
        }
    }

    static func hit(ray: Ray, terrain: Terrain3D) -> (point: Vector3, distance: Float)? {
        guard let geometry = try? terrain.geometry() else { return nil }
        var nearest = Float.infinity
        for index in stride(from: 0, to: geometry.indices.count, by: 3) {
            let a = geometry.positions[Int(geometry.indices[index])]
            let b = geometry.positions[Int(geometry.indices[index + 1])]
            let c = geometry.positions[Int(geometry.indices[index + 2])]
            if let distance = EditorMeshPicking.triangleDistance(ray: ray, a: a, b: b, c: c), distance < nearest {
                nearest = distance
            }
        }
        guard nearest.isFinite else { return nil }
        return (ray.origin + ray.direction * nearest, nearest)
    }
}
