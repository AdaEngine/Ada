import AdaAssets
@_spi(Internal) import AdaRender
import Math

extension TerrainVolumePreparedMesh {
    /// Flattens the selected static model scene into a closed solid under complete inherited transforms.
    /// The byte allowance charges retained source geometry and conservative flattening/validation staging.
    public init(
        operation: TerrainVolumeOperation,
        model: ModelAsset3D,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        maximumValidationWork: Int = 8_388_608
    ) throws {
        try operation.validate()
        guard case let .mesh(_, scene) = operation.operand else { throw TerrainVolumeFieldError.mismatchedMesh }
        guard maximumBytes >= 0 else { throw TerrainVolumeFieldError.invalidConfiguration }
        let prototype = try TerrainMeshPrototype(model: model, scene: scene)
        guard prototype.retainedGeometryBytes <= maximumBytes else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
        var remaining = maximumBytes - prototype.retainedGeometryBytes
        var indexCount = 0
        // Bounds copies, welded topology, BVH and validation scratch in addition to the source model.
        let bytesPerIndex = 512
        for node in prototype.parts {
            for group in node.mesh.models {
                for part in group.parts {
                    try Task.checkCancellation()
                    guard part.indexCount <= 196_608 - indexCount, part.indexCount <= remaining / bytesPerIndex else {
                        throw TerrainVolumeFieldError.memoryBudgetExceeded
                    }
                    remaining -= part.indexCount * bytesPerIndex
                    // MeshBuffer.elements copies the full accessor, including unused imported rows.
                    // Reserve it before any flattening; repeated scene references charge their copies too.
                    let positionCount = part.meshDescriptor.positions.count
                    guard positionCount <= remaining / MemoryLayout<Vector3>.stride else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
                    remaining -= positionCount * MemoryLayout<Vector3>.stride
                    indexCount += part.indexCount
                }
            }
        }
        var positions: [Vector3] = [], indices: [UInt32] = []
        positions.reserveCapacity(indexCount); indices.reserveCapacity(indexCount)
        for node in prototype.parts {
            for group in node.mesh.models {
                for part in group.parts {
                    let source = part.meshDescriptor, vertices = source.positions.elements
                    let start = indices.count
                    for (offset, sourceIndex) in source.indicies.prefix(part.indexCount).enumerated() {
                        if offset.isMultiple(of: 256) { try Task.checkCancellation() }
                        guard let index = Int(exactly: sourceIndex), vertices.indices.contains(index) else { throw ScalarMeshSolidError.invalidMesh }
                        let position = (node.transform * Vector4(vertices[index], 1)).xyz
                        positions.append(position); indices.append(UInt32(indices.count))
                    }
                    // Reflection changes geometric winding; normalize each inherited node independently.
                    if node.transform.determinant < 0 {
                        for index in stride(from: start, to: indices.count, by: 3) { indices.swapAt(index + 1, index + 2) }
                    }
                }
            }
        }
        try self.init(operation: operation, positions: positions, indices: indices, maximumValidationWork: maximumValidationWork)
    }
}
