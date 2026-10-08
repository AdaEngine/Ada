import Foundation

extension NativeGLTFLoader {
    func decodeAccessor(_ accessorIndex: Int, gltf: GLTF, buffers: [Data]) throws -> DecodedAccessor {
        guard let accessors = gltf.accessors, accessors.indices.contains(accessorIndex) else {
            throw GLTFError.invalidAccessorIndex(accessorIndex)
        }
        let accessor = accessors[accessorIndex]
        let componentSize = try componentSize(for: accessor.componentType)
        let componentCount = try componentCount(for: accessor.type)
        guard accessor.count >= 1, accessor.count <= Int.max / componentCount else {
            throw GLTFError.bufferOutOfBounds
        }
        var values = [Double](repeating: 0, count: accessor.count * componentCount)

        if let bufferViewIndex = accessor.bufferView {
            guard let bufferViews = gltf.bufferViews, bufferViews.indices.contains(bufferViewIndex) else {
                throw GLTFError.invalidBufferViewIndex(bufferViewIndex)
            }
            let bufferView = bufferViews[bufferViewIndex]
            guard buffers.indices.contains(bufferView.buffer) else {
                throw GLTFError.invalidBufferIndex(bufferView.buffer)
            }
            let elementSize = componentSize * componentCount
            let byteStride = bufferView.byteStride ?? elementSize
            guard byteStride >= elementSize else {
                throw GLTFError.invalidStride
            }
            let bufferViewOffset = bufferView.byteOffset ?? 0
            let bufferViewEnd = bufferViewOffset + bufferView.byteLength
            let startOffset = bufferViewOffset + (accessor.byteOffset ?? 0)
            let buffer = buffers[bufferView.buffer]

            for elementIndex in 0..<accessor.count {
                let elementOffset = startOffset + elementIndex * byteStride
                guard
                    elementOffset >= bufferViewOffset,
                    elementOffset + elementSize <= bufferViewEnd,
                    elementOffset + elementSize <= buffer.count
                else {
                    throw GLTFError.bufferOutOfBounds
                }
                for componentIndex in 0..<componentCount {
                    values[elementIndex * componentCount + componentIndex] = try readComponent(
                        buffer,
                        at: elementOffset + componentIndex * componentSize,
                        componentType: accessor.componentType,
                        normalized: accessor.normalized ?? false
                    )
                }
            }
        }

        if let sparse = accessor.sparse {
            guard sparse.count >= 1, sparse.count <= accessor.count else {
                throw GLTFError.sparseIndexOutOfBounds
            }
            let sparseIndices = try decodeSparseIndices(sparse.indices, count: sparse.count, gltf: gltf, buffers: buffers)
            let sparseValues = try decodeSparseValues(
                sparse.values,
                count: sparse.count,
                componentType: accessor.componentType,
                componentCount: componentCount,
                normalized: accessor.normalized ?? false,
                gltf: gltf,
                buffers: buffers
            )
            for sparseIndex in 0..<sparse.count {
                let destinationIndex = sparseIndices[sparseIndex]
                guard destinationIndex < accessor.count else {
                    throw GLTFError.sparseIndexOutOfBounds
                }
                for componentIndex in 0..<componentCount {
                    values[destinationIndex * componentCount + componentIndex] = sparseValues[sparseIndex * componentCount + componentIndex]
                }
            }
        }

        return DecodedAccessor(values: values, componentCount: componentCount)
    }

    private func decodeSparseIndices(
        _ indices: GLTF.Accessor.Sparse.Indices,
        count: Int,
        gltf: GLTF,
        buffers: [Data]
    ) throws -> [Int] {
        guard [5121, 5123, 5125].contains(indices.componentType) else {
            throw GLTFError.invalidComponentType(indices.componentType)
        }
        let data = try getBufferViewData(indices.bufferView, gltf: gltf, buffers: buffers)
        let size = try componentSize(for: indices.componentType)
        let offset = indices.byteOffset ?? 0
        guard offset >= 0, offset + count * size <= data.count else {
            throw GLTFError.bufferOutOfBounds
        }
        return try (0..<count)
            .map {
                Int(try readComponent(data, at: offset + $0 * size, componentType: indices.componentType, normalized: false))
            }
    }

    private func decodeSparseValues(
        _ sparseValues: GLTF.Accessor.Sparse.Values,
        count: Int,
        componentType: Int,
        componentCount: Int,
        normalized: Bool,
        gltf: GLTF,
        buffers: [Data]
    ) throws -> [Double] {
        let data = try getBufferViewData(sparseValues.bufferView, gltf: gltf, buffers: buffers)
        let size = try componentSize(for: componentType)
        let offset = sparseValues.byteOffset ?? 0
        let valueCount = count * componentCount
        guard offset >= 0, offset + valueCount * size <= data.count else {
            throw GLTFError.bufferOutOfBounds
        }
        return try (0..<valueCount)
            .map {
                try readComponent(data, at: offset + $0 * size, componentType: componentType, normalized: normalized)
            }
    }

    private func componentSize(for componentType: Int) throws -> Int {
        switch componentType {
        case 5120,
            5121:
            return 1
        case 5122,
            5123:
            return 2
        case 5125,
            5126:
            return 4
        default: throw GLTFError.invalidComponentType(componentType)
        }
    }

    private func componentCount(for accessorType: String) throws -> Int {
        switch accessorType {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4",
            "MAT2":
            return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: throw GLTFError.invalidAccessorType(accessorType)
        }
    }

    private func readComponent(_ data: Data, at offset: Int, componentType: Int, normalized: Bool) throws -> Double {
        let rawValue: Double
        switch componentType {
        case 5120:
            rawValue = Double(Int8(bitPattern: data[offset]))
        case 5121:
            rawValue = Double(data[offset])
        case 5122:
            rawValue = Double(Int16(bitPattern: readUInt16(data, at: offset)))
        case 5123:
            rawValue = Double(readUInt16(data, at: offset))
        case 5125:
            rawValue = Double(readUInt32(data, at: offset))
        case 5126:
            rawValue = Double(Float(bitPattern: readUInt32(data, at: offset)))
        default:
            throw GLTFError.invalidComponentType(componentType)
        }

        guard normalized else {
            return rawValue
        }
        switch componentType {
        case 5120: return max(rawValue / 127, -1)
        case 5121: return rawValue / 255
        case 5122: return max(rawValue / 32767, -1)
        case 5123: return rawValue / 65535
        default: return rawValue
        }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    struct DecodedAccessor {
        let values: [Double]
        let componentCount: Int
    }
}
