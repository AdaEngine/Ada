import Foundation

extension GLTFImportResult {
    /// Validates vertex streams and indexed references before a model creates GPU buffers.
    /// Empty metadata-only primitives remain valid; renderable streams require POSITION.
    public func validateGeometry() throws {
        for mesh in meshes {
            for primitive in mesh.primitives {
                guard let positions = primitive.attributes[.position] else {
                    if primitive.attributes.isEmpty && primitive.indices?.isEmpty != false { continue }
                    throw GLTFGeometryError.missingPositions
                }
                guard positions.componentCount == 3 else {
                    throw GLTFGeometryError.invalidAttribute("POSITION")
                }
                let count = positions.count
                for (attribute, data) in primitive.attributes {
                    let components: Bool
                    switch attribute {
                    case .position, .normal: components = data.componentCount == 3
                    case .tangent, .joints, .weights: components = data.componentCount == 4
                    case .texCoord: components = data.componentCount == 2
                    case .color: components = data.componentCount == 3 || data.componentCount == 4
                    case .custom: components = data.componentCount > 0
                    }
                    guard components, data.componentCount > 0, data.values.count.isMultiple(of: data.componentCount),
                        data.count == count, data.values.allSatisfy(\.isFinite)
                    else {
                        throw GLTFGeometryError.invalidAttribute(String(describing: attribute))
                    }
                }
                guard primitive.indices?.allSatisfy({ UInt64($0) < UInt64(count) }) != false else {
                    throw GLTFGeometryError.invalidIndices
                }
            }
        }
    }
}

public enum GLTFGeometryError: LocalizedError, Equatable {
    case missingPositions, invalidAttribute(String), invalidIndices

    public var errorDescription: String? {
        switch self {
        case .missingPositions: "glTF vertex data requires a POSITION attribute"
        case .invalidAttribute(let name): "glTF attribute \(name) must have finite values and match the POSITION vertex count and required dimensions"
        case .invalidIndices: "glTF indices reference vertices outside the POSITION attribute"
        }
    }
}
