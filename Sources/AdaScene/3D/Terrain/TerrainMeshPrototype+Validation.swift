@_spi(Internal) import AdaRender
import AdaUtils
import Math
import OrderedCollections

struct TerrainPrototypeGeometryBudget {
    var remainingVertices = 1_048_576
    var remainingIndices = 6_291_456
}

extension TerrainMeshPrototype {
    static func validateGeometry(_ mesh: Mesh, budget: inout TerrainPrototypeGeometryBudget) throws {
        guard mesh.models.count <= maximumDrawParts else {
            throw TerrainMeshPrototypeError.budgetExceeded
        }
        var partCount = 0
        for group in mesh.models {
            guard group.parts.count <= maximumDrawParts - partCount else {
                throw TerrainMeshPrototypeError.budgetExceeded
            }
            partCount += group.parts.count
            for part in group.parts {
                let descriptor = part.meshDescriptor
                guard part.primitiveTopology == .triangleList, part.indexCount >= 0, part.indexCount.isMultiple(of: 3),
                    part.indexCount <= descriptor.indicies.count,
                    let positions = descriptor.buffers[.positions], positions.elementType == .vector3
                else {
                    throw TerrainMeshPrototypeError.unsupportedGeometry
                }
                let count = positions.count
                guard count <= budget.remainingVertices, part.indexCount <= budget.remainingIndices else {
                    throw TerrainMeshPrototypeError.budgetExceeded
                }
                budget.remainingVertices -= count
                budget.remainingIndices -= part.indexCount
                if descriptor.buffers[.jointIndices] != nil || descriptor.buffers[.jointWeights] != nil {
                    throw TerrainMeshPrototypeError.unsupportedDeformation
                }
                try validateAttributes(descriptor, count: count)
                var expected = descriptor.getMeshVertexBufferDescriptor()
                let stride = expected.layouts[0].stride
                let indexSize = part.isUInt32 ? MemoryLayout<UInt32>.stride : MemoryLayout<UInt16>.stride
                guard stride > 0, part.vertexDescriptor == expected, part.vertexBuffer.binding == 0,
                    count <= part.vertexBuffer.length / stride,
                    (part.indexBuffer.indexFormat == .uInt32) == part.isUInt32,
                    part.indexCount <= part.indexBuffer.length / indexSize,
                    descriptor.indicies.prefix(part.indexCount).allSatisfy({ UInt64($0) < UInt64(count) && (part.isUInt32 || $0 <= UInt32(UInt16.max)) })
                else {
                    throw TerrainMeshPrototypeError.unsupportedGeometry
                }
            }
        }
    }

    private static func validateAttributes(_ descriptor: MeshDescriptor, count: Int) throws {
        for (id, buffer) in descriptor.buffers {
            guard buffer.count == count else {
                throw TerrainMeshPrototypeError.unsupportedGeometry
            }
            let valid: Bool
            switch id {
            case .positions, .normals:
                valid =
                    buffer.elementType == .vector3
                    && buffer.get(as: Vector3.self)?.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                    } == true
            case .textureCoordinates, .textureCoordinates1:
                valid =
                    buffer.elementType == .vector2
                    && buffer.get(as: Vector2.self)?.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite
                    } == true
            case .tangents:
                valid =
                    buffer.elementType == .vector4
                    && buffer.get(as: Vector4.self)?.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
                    } == true
            case .colors:
                valid =
                    buffer.elementType == .vector4
                    && buffer.get(as: Color.self)?.allSatisfy {
                        $0.red.isFinite && $0.green.isFinite && $0.blue.isFinite && $0.alpha.isFinite
                    } == true
            default:
                valid = false
            }
            guard valid else {
                throw TerrainMeshPrototypeError.unsupportedGeometry
            }
        }
    }
}
