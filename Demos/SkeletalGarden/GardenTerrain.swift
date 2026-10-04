import AdaEngine
@_spi(Internal) import AdaRender
import Foundation

/// Shared render/collision geometry: 48 meters across, 0.75 meter cells, a flat central plaza.
struct GardenTerrain: Sendable {
    static let extent: Float = 24
    static let cells = 64
    static let spacing: Float = extent * 2 / Float(cells)
    let vertices: [Vector3]
    let indices: [UInt32]

    init() {
        var vertices: [Vector3] = []
        var indices: [UInt32] = []
        for row in 0...Self.cells {
            for column in 0...Self.cells {
                let x = -Self.extent + Float(column) * Self.spacing
                let z = -Self.extent + Float(row) * Self.spacing
                vertices.append([x, Self.height(x: x, z: z), z])
            }
        }
        for row in 0..<Self.cells {
            for column in 0..<Self.cells {
                let first = UInt32(row * (Self.cells + 1) + column)
                let next = first + UInt32(Self.cells + 1)
                indices.append(contentsOf: [first, next, next + 1, first, next + 1, first + 1])
            }
        }
        self.vertices = vertices
        self.indices = indices
    }

    /// Interpolates the same triangle split as the collision mesh, for grounded prop placement.
    func surfaceHeight(x: Float, z: Float) -> Float {
        let gx = min(max((x + Self.extent) / Self.spacing, 0), Float(Self.cells) - 0.0001)
        let gz = min(max((z + Self.extent) / Self.spacing, 0), Float(Self.cells) - 0.0001)
        let column = Int(gx), row = Int(gz)
        let fx = gx - Float(column), fz = gz - Float(row)
        let first = row * (Self.cells + 1) + column
        let a = vertices[first].y, b = vertices[first + Self.cells + 1].y
        let c = vertices[first + Self.cells + 2].y, d = vertices[first + 1].y
        return fx <= fz ? a + (c - b) * fx + (b - a) * fz : a + (d - a) * fx + (c - d) * fz
    }

    func descriptor() -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "Garden rolling terrain")
        descriptor.positions = MeshBuffer(vertices)
        var normals = Array(repeating: Vector3.zero, count: vertices.count)
        var visible: [UInt32] = []
        for index in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[index]), b = Int(indices[index + 1]), c = Int(indices[index + 2])
            let normal = (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
            normals[a] += normal; normals[b] += normal; normals[c] += normal
            let center = (vertices[a] + vertices[b] + vertices[c]) / 3
            // The original textured plaza covers the central 12x12 meters.
            if abs(center.x) >= 6 || abs(center.z) >= 6 { visible.append(contentsOf: indices[index..<index + 3]) }
        }
        descriptor.normals = MeshBuffer(normals.map(\.normalized))
        let colors: [Color] = vertices.map { point in
            let trail = abs(point.x - Self.trailX(z: point.z))
            let path = max(0, 1 - trail / 1.4)
            let variation = 0.035 * Math.sin(point.x * 1.3 + point.z * 0.8)
            let grass = Vector3(0.24 + variation, 0.36 + variation, 0.16 + variation * 0.4)
            let gravel = Vector3(0.48, 0.41, 0.27)
            let color = grass + (gravel - grass) * path
            return Color(red: color.x, green: color.y, blue: color.z)
        }
        descriptor.colors = MeshBuffer(colors)
        descriptor.indicies = visible
        return descriptor
    }

    static func trailX(z: Float) -> Float { 2.2 * Math.sin(z * 0.19) }

    private static func height(x: Float, z: Float) -> Float {
        let distance = max(abs(x), abs(z))
        let factor = min(max((distance - 6) / 3, 0), 1)
        let blend = factor * factor * (3 - 2 * factor)
        let hill = bump(x: x, z: z, center: [12, 11], spread: 55) * 3.4
            + bump(x: x, z: z, center: [-14, 12], spread: 38) * 2.3
            + bump(x: x, z: z, center: [14, -14], spread: 40) * 1.8
            - bump(x: x, z: z, center: [-11, -10], spread: 15) * 0.85
        let noise = (Math.sin(x * 0.58) * Math.cos(z * 0.41) + Math.sin(z * 1.1 + x * 0.3) * 0.25) * 0.16
        let trailWeight = min(abs(x - trailX(z: z)) / 2, 1)
        return blend * (hill + noise * trailWeight)
    }

    private static func bump(x: Float, z: Float, center: Vector2, spread: Float) -> Float {
        let dx = x - center.x, dz = z - center.y
        return Float(exp(-Double((dx * dx + dz * dz) / spread)))
    }
}

struct GardenRandom {
    private var state: UInt64 = 0xADAE_3D_2026

    mutating func next(_ lower: Float, _ upper: Float) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return lower + (upper - lower) * Float(state >> 40) / Float(1 << 24)
    }
}
