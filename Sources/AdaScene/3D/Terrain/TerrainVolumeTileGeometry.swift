@_spi(Internal) import AdaRender
import Foundation
import Math

struct TerrainVolumePreparedTile: Sendable {
    let generation = UUID()
    let inputs: [UUID]
    let heightfieldEdges: TerrainLODEdges
    let descriptor: MeshDescriptor
    let chargedBytes: Int
}

enum TerrainVolumeTileGeometry {
    static func prepare(
        coordinates: [TerrainVolumeBrickCoordinate],
        cache: TerrainVolumeCache,
        field: TerrainVolumeField,
        snapshot: TerrainHeightTileSnapshot,
        heightfieldEdges: TerrainLODEdges,
        maximumBytes: Int
    ) throws -> TerrainVolumePreparedTile {
        var positions: [Vector3] = [], normals: [Vector3] = [], indices: [UInt32] = [], inputs: [UUID] = []
        var remaining = maximumBytes
        var normalWork = try TerrainVolumeFieldWork(268_435_456)
        for coordinate in coordinates {
            try Task.checkCancellation()
            guard let brick = cache.brick(at: coordinate), let generation = cache.brickGeneration(at: coordinate) else { throw TerrainSourceError.changedDuringBuild }
            let surface = try field.surface(of: brick, maximumTriangles: min(262_144, remaining / 1_024))
            let triangles = surface.indices.count / 3
            guard triangles <= remaining / 1_024, UInt64(surface.positions.count) <= UInt64(UInt32.max) - UInt64(positions.count) else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= triangles * 1_024
            let offset = UInt32(positions.count)
            positions.append(contentsOf: surface.positions); normals.append(contentsOf: try field.canonicalNormals(for: surface, budget: &normalWork))
            for index in surface.indices { indices.append(offset + index) }
            inputs.append(generation)
        }
        let seamTriangles = try TerrainVolumeSeamGeometry.conform(
            positions: &positions,
            normals: &normals,
            indices: &indices,
            snapshot: snapshot,
            edges: heightfieldEdges,
            maximumTriangles: remaining / 1_024
        )
        remaining -= seamTriangles * 1_024
        var descriptor = MeshDescriptor(name: "Hybrid terrain volume tile")
        descriptor.positions = MeshBuffer(positions); descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(positions.map { Vector2($0.x, $0.z) })
        descriptor.indicies = indices
        return .init(inputs: inputs, heightfieldEdges: heightfieldEdges, descriptor: descriptor, chargedBytes: maximumBytes - remaining)
    }
}
