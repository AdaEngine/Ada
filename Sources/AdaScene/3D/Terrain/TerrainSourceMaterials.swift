@_spi(Internal) import AdaRender
import Foundation
import Math

enum TerrainSourceMaterials {
    static let layerIDs = MeshDescriptor.custom("terrainMaterialLayerIDs", type: Vector4.self)
    static let weights = MeshDescriptor.custom("terrainMaterialWeights", type: Vector4.self)
    static let surfaceTint = MeshDescriptor.custom("terrainSurfaceTint", type: Vector4.self)
    static let roughnessMask = MeshDescriptor.custom("terrainSurfaceRoughnessMask", type: Float.self)

    /// Canonical material rows stay separate from render LOD vertices. The renderer can sample this
    /// full-resolution field rather than interpolating incompatible palette indices as vertex colors.
    static func prepare(_ snapshot: TerrainHeightTileSnapshot, storage: TerrainHeightStorage, resolver: TerrainMaterialResolver) throws -> (descriptor: MeshDescriptor, evaluations: Int) {
        var descriptor = snapshot.meshDescriptor()
        let positions = descriptor.positions.elements
        guard let normals = descriptor.normals?.elements, normals.count == positions.count else { throw TerrainLODMeshError.invalidSnapshot }
        var ids: [Vector4] = [], weights: [Vector4] = []
        ids.reserveCapacity(positions.count)
        weights.reserveCapacity(positions.count)
        let width = snapshot.cellCountX + 1
        let surface = storage.surfaceSnapshot()
        let painted = surface.hasSurfaceOverrides(in: snapshot.coordinate, cellCountX: snapshot.cellCountX, cellCountZ: snapshot.cellCountZ)
        var tints = painted ? [Vector4](repeating: [1, 1, 1, 0], count: positions.count) : []
        var roughnessMasks = painted ? [Float](repeating: 0, count: positions.count) : []
        var evaluations = 0
        for index in positions.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let x = snapshot.coordinate.x * TerrainHeightStorage.cellsPerTile + index % width
            let z = snapshot.coordinate.z * TerrainHeightStorage.cellsPerTile + index / width
            let point = TerrainGridPoint(x: x, z: z)
            var curvature: Double = 0
            if resolver.needsCurvature {
                curvature = Self.curvature(x: x, z: z, center: Double(positions[index].y), storage: storage)
            }
            let paint = surface.sample(at: point)
            if painted, let paint {
                tints[index] = [
                    1 + (paint.tint.x - 1) * paint.tintStrength,
                    1 + (paint.tint.y - 1) * paint.tintStrength,
                    1 + (paint.tint.z - 1) * paint.tintStrength,
                    paint.roughness * paint.roughnessStrength,
                ]
                roughnessMasks[index] = paint.roughnessStrength
            }
            let sample = try resolver.resolve(
                position: positions[index],
                normal: normals[index],
                curvature: curvature,
                paint: paint,
                mask: { surface.mask(at: point, id: $0) }
            )
            evaluations += 1
            ids.append(sample.ids)
            weights.append(sample.weights)
        }
        descriptor[layerIDs] = MeshBuffer(ids)
        descriptor[Self.weights] = MeshBuffer(weights)
        if painted {
            descriptor[surfaceTint] = MeshBuffer(tints)
            descriptor[roughnessMask] = MeshBuffer(roughnessMasks)
        }
        return (descriptor, evaluations)
    }

    /// Each volume triangle has an independent three-corner material field. UV1 addresses
    /// that field; UV0 retains terrain X/Z for triplanar textures and deterministic detiling.
    static func prepareVolume(_ source: MeshDescriptor, storage: TerrainHeightStorage, resolver: TerrainMaterialResolver) throws -> (descriptor: MeshDescriptor, evaluations: Int) {
        let vertices = source.positions.elements, indices = source.indicies
        guard let sourceNormals = source.normals?.elements, sourceNormals.count == vertices.count,
            indices.count.isMultiple(of: 3), indices.count <= 786_432 else { throw TerrainLODMeshError.invalidSnapshot }
        let triangles = indices.count / 3
        let columns = max(1, Int(ceil(Double(triangles).squareRoot())))
        let width = columns * 2, height = max(1, (triangles + columns - 1) / columns) * 2
        var ids = [Vector4](repeating: .zero, count: width * height)
        var weights = ids
        var positions: [Vector3] = [], normals: [Vector3] = [], fieldUV: [Vector2] = []
        positions.reserveCapacity(indices.count); normals.reserveCapacity(indices.count); fieldUV.reserveCapacity(indices.count)
        let surface = storage.surfaceSnapshot()
        for triangle in 0..<triangles {
            if triangle.isMultiple(of: 128) { try Task.checkCancellation() }
            let x = (triangle % columns) * 2, y = (triangle / columns) * 2
            for corner in 0..<3 {
                let index = Int(indices[triangle * 3 + corner])
                guard vertices.indices.contains(index) else { throw TerrainLODMeshError.invalidSnapshot }
                let position = vertices[index], normal = sourceNormals[index]
                let gx = Int(((Double(position.x) - Double(storage.origin.x)) / Double(storage.spacing)).rounded())
                let gz = Int(((Double(position.z) - Double(storage.origin.y)) / Double(storage.spacing)).rounded())
                let point = TerrainGridPoint(x: gx, z: gz)
                let sample = try resolver.resolve(
                    position: position,
                    normal: normal,
                    curvature: 0,
                    paint: surface.sample(at: point),
                    mask: { surface.mask(at: point, id: $0) }
                )
                let dx = corner == 1 ? 1 : 0, dy = corner == 2 ? 1 : 0
                let at = (y + dy) * width + x + dx
                ids[at] = sample.ids; weights[at] = sample.weights
                positions.append(position); normals.append(normal); fieldUV.append([Float(x + dx), Float(y + dy)])
            }
        }
        var result = MeshDescriptor(name: "Hybrid terrain material surface")
        result.positions = MeshBuffer(positions); result.normals = MeshBuffer(normals)
        result.textureCoordinates = MeshBuffer(positions.map { Vector2($0.x, $0.z) })
        result[MeshDescriptor.textureCoordinates1] = MeshBuffer(fieldUV)
        result.indicies = positions.indices.map { UInt32($0) }
        result[layerIDs] = MeshBuffer(ids); result[Self.weights] = MeshBuffer(weights)
        return (result, positions.count)
    }

    static func displayGeometry(_ source: MeshDescriptor) -> MeshDescriptor {
        var result = source
        result[layerIDs] = nil; result[weights] = nil
        result[surfaceTint] = nil; result[roughnessMask] = nil
        return result
    }

    static func curvature(x: Int, z: Int, center: Double, storage: TerrainHeightStorage) -> Double {
        func secondDerivative(dx: Int, dz: Int) -> Double {
            let minus = storage.heightForBrush(at: .init(x: x - dx, z: z - dz)).map(Double.init)
            let plus = storage.heightForBrush(at: .init(x: x + dx, z: z + dz)).map(Double.init)
            if let minus, let plus {
                return minus + plus - 2 * center
            }
            // True authored edges use the available one-sided stencil; halos still use centered differences.
            if let plus, let next = storage.heightForBrush(at: .init(x: x + 2 * dx, z: z + 2 * dz)) {
                return center - 2 * plus + Double(next)
            }
            if let minus, let next = storage.heightForBrush(at: .init(x: x - 2 * dx, z: z - 2 * dz)) {
                return center - 2 * minus + Double(next)
            }
            // Two samples establish a line but cannot establish nonzero curvature.
            return 0
        }
        return (secondDerivative(dx: 1, dz: 0) + secondDerivative(dx: 0, dz: 1)) / (Double(storage.spacing) * Double(storage.spacing))
    }
}
