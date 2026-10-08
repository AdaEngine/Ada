import Math

extension NativeGLTFLoader {
    func importSkinning(
        _ primitive: GLTF.Mesh.Primitive,
        attributes: [GLTFImportResult.Attribute: GLTFImportResult.Accessor],
        gltf: GLTF
    ) throws -> GLTFImportResult.Skinning? {
        for attribute in attributes.keys {
            switch attribute {
            case .joints(let index), .weights(let index):
                guard index == 0 else { throw GLTFError.unsupportedJointSet(index) }
            default: break
            }
        }
        guard attributes[.joints(0)] != nil || attributes[.weights(0)] != nil else {
            return nil
        }
        guard let jointsIndex = primitive.attributes["JOINTS_0"], let weightsIndex = primitive.attributes["WEIGHTS_0"],
            let joints = attributes[.joints(0)], let weights = attributes[.weights(0)], let positions = attributes[.position]
        else {
            throw GLTFError.invalidSkinningAttributes
        }
        let jointAccessor = try checkedAccessor(jointsIndex, gltf: gltf)
        let weightAccessor = try checkedAccessor(weightsIndex, gltf: gltf)
        guard jointAccessor.type == "VEC4", [5121, 5123].contains(jointAccessor.componentType), jointAccessor.normalized != true,
            weightAccessor.type == "VEC4",
            weightAccessor.componentType == 5126 && weightAccessor.normalized != true
                || [5121, 5123].contains(weightAccessor.componentType) && weightAccessor.normalized == true,
            joints.count == positions.count, weights.count == positions.count,
            joints.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Float(UInt16.max) && $0.rounded() == $0 }),
            weights.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else {
            throw GLTFError.invalidSkinningAttributes
        }
        var jointIndices: [SIMD4<UInt16>] = []
        var normalizedWeights: [Vector4] = []
        jointIndices.reserveCapacity(joints.count)
        normalizedWeights.reserveCapacity(joints.count)
        for index in 0..<joints.count {
            let offset = index * 4
            let values = weights.values[offset..<offset + 4]
            let sum = values.reduce(Float.zero) { $0 + $1 }
            guard sum > 0 else { throw GLTFError.invalidSkinningAttributes }
            jointIndices.append(SIMD4(
                UInt16(joints.values[offset]),
                UInt16(joints.values[offset + 1]),
                UInt16(joints.values[offset + 2]),
                UInt16(joints.values[offset + 3])
            ))
            normalizedWeights.append(Vector4(
                weights.values[offset] / sum,
                weights.values[offset + 1] / sum,
                weights.values[offset + 2] / sum,
                weights.values[offset + 3] / sum
            ))
        }
        return GLTFImportResult.Skinning(jointIndices: jointIndices, weights: normalizedWeights)
    }
}
