import AdaECS
@_spi(Internal) import AdaRender
import Foundation
import Math

/// A square, editable height field, centred on the local X/Z origin. Heights are row-major along Z.
/// Terrain is rendered by `Model3DPlugin`; static collision is created when `Physics3DPlugin` is installed.
public struct Terrain3D: Component, Codable, Equatable {
    public var resolution: Int
    public var size: Float
    public var heights: [Float]
    public var color: Vector4
    public var generatesCollision: Bool

    public init(resolution: Int = 65, size: Float = 64) {
        self.resolution = min(257, max(2, resolution))
        self.size = size.isFinite && size > 0 ? size : 64
        self.heights = Array(repeating: 0, count: self.resolution * self.resolution)
        self.color = Vector4(0.28, 0.43, 0.18, 1)
        self.generatesCollision = true
    }

    public enum ValidationError: Error { case invalidHeightField }

    public func validate() throws {
        guard (2...257).contains(resolution), size.isFinite, size > 0,
              heights.count == resolution * resolution, heights.allSatisfy({ $0.isFinite }),
              color.x.isFinite, color.y.isFinite, color.z.isFinite, color.w.isFinite else {
            throw ValidationError.invalidHeightField
        }
    }

    private enum CodingKeys: CodingKey { case resolution, size, heights, color, generatesCollision }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decode(Int.self, forKey: .resolution)
        size = try container.decode(Float.self, forKey: .size)
        heights = try container.decode([Float].self, forKey: .heights)
        color = try container.decodeIfPresent(Vector4.self, forKey: .color) ?? Vector4(0.28, 0.43, 0.18, 1)
        generatesCollision = try container.decodeIfPresent(Bool.self, forKey: .generatesCollision) ?? true
        try validate()
    }

    /// CPU geometry shared by drawing, collision and editor picking. Triangles face upward.
    public func geometry() throws -> (positions: [Vector3], normals: [Vector3], indices: [UInt32]) {
        try validate()
        let step = size / Float(resolution - 1)
        var positions: [Vector3] = []
        var normals: [Vector3] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(heights.count)
        normals.reserveCapacity(heights.count)
        indices.reserveCapacity((resolution - 1) * (resolution - 1) * 6)
        for z in 0..<resolution {
            for x in 0..<resolution {
                positions.append(Vector3(Float(x) * step - size / 2, heights[z * resolution + x], Float(z) * step - size / 2))
                let left = max(0, x - 1), right = min(resolution - 1, x + 1)
                let back = max(0, z - 1), front = min(resolution - 1, z + 1)
                let dx = (heights[z * resolution + right] - heights[z * resolution + left]) / (Float(right - left) * step)
                let dz = (heights[front * resolution + x] - heights[back * resolution + x]) / (Float(front - back) * step)
                normals.append(Vector3(-dx, 1, -dz).normalized)
                if x < resolution - 1, z < resolution - 1 {
                    let a = UInt32(z * resolution + x), b = a + 1, c = a + UInt32(resolution), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        return (positions, normals, indices)
    }

    public func meshDescriptor() throws -> MeshDescriptor {
        let geometry = try geometry()
        var descriptor = MeshDescriptor(name: "Terrain")
        descriptor.positions = MeshBuffer(geometry.positions)
        descriptor.normals = MeshBuffer(geometry.normals)
        descriptor.textureCoordinates = MeshBuffer(geometry.positions.map { Vector2($0.x / size + 0.5, $0.z / size + 0.5) })
        descriptor.indicies = geometry.indices
        return descriptor
    }

    /// Height on the same triangles used by rendering and collision; nil outside the field.
    public func surfaceHeight(at point: Vector2) -> Float? {
        guard (2...257).contains(resolution), heights.count == resolution * resolution,
              size.isFinite, size > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let x = (point.x / size + 0.5) * Float(resolution - 1)
        let z = (point.y / size + 0.5) * Float(resolution - 1)
        guard x >= 0, z >= 0, x <= Float(resolution - 1), z <= Float(resolution - 1) else { return nil }
        let ix = min(resolution - 2, Int(x)), iz = min(resolution - 2, Int(z))
        let fx = x - Float(ix), fz = z - Float(iz)
        let a = heights[iz * resolution + ix], b = heights[iz * resolution + ix + 1]
        let c = heights[(iz + 1) * resolution + ix], d = heights[(iz + 1) * resolution + ix + 1]
        return fx + fz <= 1 ? a + (b - a) * fx + (c - a) * fz : d + (c - d) * (1 - fx) + (b - d) * (1 - fz)
    }
}
