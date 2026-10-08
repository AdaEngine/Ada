import Foundation
import Math

extension NativeGLTFLoader {
    func importNodes(_ gltf: GLTF) throws -> [GLTFImportResult.Node] {
        let source = gltf.nodes ?? []
        var parents = [Int?](repeating: nil, count: source.count)
        for (index, node) in source.enumerated() {
            for child in node.children ?? [] {
                guard source.indices.contains(child), child != index, parents[child] == nil else {
                    throw GLTFError.invalidNode(index)
                }
                parents[child] = index
            }
        }
        var pending = source.indices.filter { parents[$0] == nil }
        var visited = 0
        while let index = pending.popLast() {
            visited += 1
            pending.append(contentsOf: source[index].children ?? [])
        }
        guard visited == source.count else {
            throw GLTFError.invalidNode(parents.firstIndex { $0 != nil } ?? 0)
        }

        return try source.enumerated().map { index, node in
            if let mesh = node.mesh, !(gltf.meshes ?? []).indices.contains(mesh) {
                throw GLTFError.invalidNode(index)
            }
            let transform: Transform3D
            let restPose: GLTFImportResult.NodeTRS?
            if let matrix = node.matrix {
                guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
                    node.translation == nil, node.rotation == nil, node.scale == nil
                else {
                    throw GLTFError.invalidNode(index)
                }
                transform = matrixFromColumnMajor(matrix)
                restPose = nil
            } else {
                let translation = node.translation ?? [0, 0, 0]
                let rotation = node.rotation ?? [0, 0, 0, 1]
                let scale = node.scale ?? [1, 1, 1]
                guard translation.count == 3, rotation.count == 4, scale.count == 3,
                    (translation + rotation + scale).allSatisfy(\.isFinite),
                    abs(rotation.reduce(0) { $0 + $1 * $1 } - 1) < 0.001
                else {
                    throw GLTFError.invalidNode(index)
                }
                let pose = GLTFImportResult.NodeTRS(
                    translation: Vector3(translation[0], translation[1], translation[2]),
                    rotation: Quat(x: rotation[0], y: rotation[1], z: rotation[2], w: rotation[3]),
                    scale: Vector3(scale[0], scale[1], scale[2])
                )
                restPose = pose
                transform = pose.matrix
            }
            return GLTFImportResult.Node(
                name: node.name,
                transform: transform,
                children: node.children ?? [],
                meshIndex: node.mesh,
                skinIndex: node.skin,
                restPose: restPose
            )
        }
    }

    func importSkins(_ gltf: GLTF, buffers: [Data]) throws -> [GLTFImportResult.Skin] {
        let nodes = gltf.nodes ?? []
        return try (gltf.skins ?? []).enumerated().map { index, skin in
            guard !skin.joints.isEmpty, Set(skin.joints).count == skin.joints.count,
                skin.joints.allSatisfy({ nodes.indices.contains($0) })
            else {
                throw GLTFError.invalidSkin(index)
            }
            if let root = skin.skeleton {
                guard nodes.indices.contains(root) else { throw GLTFError.invalidSkin(index) }
                var pending = [root]
                var descendants: Set<Int> = []
                while let node = pending.popLast() {
                    descendants.insert(node)
                    pending.append(contentsOf: nodes[node].children ?? [])
                }
                guard skin.joints.allSatisfy({ descendants.contains($0) }) else {
                    throw GLTFError.invalidSkin(index)
                }
            }
            let matrices: [Transform3D]
            if let accessorIndex = skin.inverseBindMatrices {
                let accessor = try checkedAccessor(accessorIndex, gltf: gltf)
                guard accessor.type == "MAT4", accessor.componentType == 5126,
                    accessor.normalized != true, accessor.count >= skin.joints.count
                else {
                    throw GLTFError.invalidSkin(index)
                }
                let decoded = try decodeAccessor(accessorIndex, gltf: gltf, buffers: buffers)
                guard decoded.values.allSatisfy(\.isFinite) else { throw GLTFError.invalidSkin(index) }
                matrices = try skin.joints.indices.map { joint in
                    let offset = joint * 16
                    let values = Array(decoded.values[offset..<offset + 16]).map(Float.init)
                    guard values[3] == 0, values[7] == 0, values[11] == 0, values[15] == 1 else {
                        throw GLTFError.invalidSkin(index)
                    }
                    return matrixFromColumnMajor(values)
                }
            } else {
                matrices = Array(repeating: .identity, count: skin.joints.count)
            }
            return GLTFImportResult.Skin(
                name: skin.name, joints: skin.joints, skeletonRootIndex: skin.skeleton, inverseBindMatrices: matrices
            )
        }
    }

    func validateSkinBindings(nodes: [GLTFImportResult.Node], meshes: [GLTFImportResult.Mesh], skins: [GLTFImportResult.Skin]) throws {
        for (index, node) in nodes.enumerated() {
            guard let skinIndex = node.skinIndex else { continue }
            guard skins.indices.contains(skinIndex), let meshIndex = node.meshIndex, meshes.indices.contains(meshIndex) else {
                throw GLTFError.invalidNode(index)
            }
            for primitive in meshes[meshIndex].primitives {
                guard let skinning = primitive.skinning else { throw GLTFError.invalidSkinningAttributes }
                for joints in skinning.jointIndices {
                    guard (0..<4).allSatisfy({ Int(joints[$0]) < skins[skinIndex].joints.count }) else {
                        throw GLTFError.invalidSkinningAttributes
                    }
                }
            }
        }
    }

    func checkedAccessor(_ index: Int, gltf: GLTF) throws -> GLTF.Accessor {
        guard let accessors = gltf.accessors, accessors.indices.contains(index) else {
            throw GLTFError.invalidAccessorIndex(index)
        }
        return accessors[index]
    }

    private func matrixFromColumnMajor(_ values: [Float]) -> Transform3D {
        Transform3D(
            Vector4(values[0], values[1], values[2], values[3]),
            Vector4(values[4], values[5], values[6], values[7]),
            Vector4(values[8], values[9], values[10], values[11]),
            Vector4(values[12], values[13], values[14], values[15])
        )
    }
}
