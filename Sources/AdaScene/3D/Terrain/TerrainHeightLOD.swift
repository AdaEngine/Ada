@_spi(Internal) import AdaRender
import Foundation
import Math

/// Tile boundaries whose neighbors render one level finer. The coarse tile owns the additional seam vertices.
public struct TerrainLODEdges: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let minX = Self(rawValue: 1)
    public static let maxX = Self(rawValue: 2)
    public static let minZ = Self(rawValue: 4)
    public static let maxZ = Self(rawValue: 8)
    public static let all: Self = [.minX, .maxX, .minZ, .maxZ]
}

/// Render-only heightfield geometry; collision and editing continue to use the authoritative full-detail snapshot.
public struct TerrainLODMesh: Sendable {
    public let coordinate: TerrainTileCoordinate
    public let level: Int
    public let revision: UInt64
    public let descriptor: MeshDescriptor
}

public enum TerrainLODMeshError: LocalizedError {
    case invalidLevel
    case invalidEdges
    case partialTileStitch
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidLevel: "Terrain LOD level must be between 0 and 6"
        case .invalidEdges: "Invalid terrain LOD neighbor edge mask"
        case .partialTileStitch: "Partial terrain tiles and their neighbors require full detail"
        case .invalidSnapshot: "Terrain LOD source is missing canonical geometry attributes"
        }
    }
}

extension TerrainHeightTileSnapshot {
    /// Builds a level from 0 (full detail) through 6 (one cell), including explicit fine-neighbor seams.
    /// Partial tiles retain level 0; callers must also retain full detail on their adjoining tiles.
    public func meshLOD(level: Int, finerEdges: TerrainLODEdges = []) throws -> TerrainLODMesh {
        guard (0...6).contains(level) else { throw TerrainLODMeshError.invalidLevel }
        guard finerEdges.rawValue & ~TerrainLODEdges.all.rawValue == 0, level > 0 || finerEdges.isEmpty else { throw TerrainLODMeshError.invalidEdges }
        if cellCountX != 64 || cellCountZ != 64 {
            guard finerEdges.isEmpty else { throw TerrainLODMeshError.partialTileStitch }
            return TerrainLODMesh(coordinate: coordinate, level: 0, revision: revision, descriptor: descriptor)
        }
        if level == 0 {
            return TerrainLODMesh(coordinate: coordinate, level: 0, revision: revision, descriptor: descriptor)
        }
        let positions = descriptor.positions.elements
        guard positions.count == 4_225, let normals = descriptor.normals?.elements, normals.count == positions.count,
            let uvs = descriptor.textureCoordinates?.elements, uvs.count == positions.count
        else { throw TerrainLODMeshError.invalidSnapshot }
        let step = 1 << level
        var builder = TerrainLODBuilder(sourcePositions: positions, sourceNormals: normals, sourceUVs: uvs)
        builder.reserve(side: 64 / step)
        for z in stride(from: 0, to: 64, by: step) {
            for x in stride(from: 0, to: 64, by: step) { builder.quad(x: x, z: z, step: step, edges: finerEdges) }
        }
        var mesh = MeshDescriptor(name: "Terrain Tile \(coordinate.x),\(coordinate.z) LOD \(level)")
        mesh.positions = MeshBuffer(builder.positions)
        mesh.normals = MeshBuffer(builder.normals)
        mesh.textureCoordinates = MeshBuffer(builder.uvs)
        mesh.indicies = builder.indices
        return TerrainLODMesh(coordinate: coordinate, level: level, revision: revision, descriptor: mesh)
    }
}

private struct TerrainLODBuilder {
    let sourcePositions: [Vector3]
    let sourceNormals: [Vector3]
    let sourceUVs: [Vector2]
    var positions: [Vector3] = []
    var normals: [Vector3] = []
    var uvs: [Vector2] = []
    var indices: [UInt32] = []
    private var vertices: [Int: UInt32] = [:]

    init(sourcePositions: [Vector3], sourceNormals: [Vector3], sourceUVs: [Vector2]) {
        self.sourcePositions = sourcePositions
        self.sourceNormals = sourceNormals
        self.sourceUVs = sourceUVs
    }

    mutating func reserve(side: Int) {
        let count = (side + 1) * (side + 1) + 8 * side
        positions.reserveCapacity(count)
        normals.reserveCapacity(count)
        uvs.reserveCapacity(count)
        vertices.reserveCapacity(count)
        indices.reserveCapacity(side * side * 6 + 48 * side)
    }

    private mutating func vertex(x: Int, z: Int) -> UInt32 {
        let source = z * 65 + x
        if let index = vertices[source] {
            return index
        }
        let index = UInt32(positions.count)
        positions.append(sourcePositions[source])
        normals.append(sourceNormals[source])
        uvs.append(sourceUVs[source])
        vertices[source] = index
        return index
    }

    mutating func quad(x: Int, z: Int, step: Int, edges: TerrainLODEdges) {
        let west = x == 0 && edges.contains(.minX), east = x + step == 64 && edges.contains(.maxX)
        let north = z == 0 && edges.contains(.minZ), south = z + step == 64 && edges.contains(.maxZ)
        let a = vertex(x: x, z: z), b = vertex(x: x + step, z: z)
        let c = vertex(x: x, z: z + step), d = vertex(x: x + step, z: z + step)
        guard west || east || north || south else {
            indices.append(contentsOf: [a, c, b, b, c, d])
            return
        }
        // Split the coarse boundary rather than collapsing fine vertices. A center fan
        // handles two stitched sides at a corner without degenerate triangles or T-junctions.
        let half = step / 2
        var boundary: [UInt32] = []
        boundary.reserveCapacity(8)
        boundary.append(a)
        if west { boundary.append(vertex(x: x, z: z + half)) }
        boundary.append(c)
        if south { boundary.append(vertex(x: x + half, z: z + step)) }
        boundary.append(d)
        if east { boundary.append(vertex(x: x + step, z: z + half)) }
        boundary.append(b)
        if north { boundary.append(vertex(x: x + half, z: z)) }
        let center = vertex(x: x + half, z: z + half)
        for index in boundary.indices { indices.append(contentsOf: [center, boundary[index], boundary[(index + 1) % boundary.count]]) }
    }
}
