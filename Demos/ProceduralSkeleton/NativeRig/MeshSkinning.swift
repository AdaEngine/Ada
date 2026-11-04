import AdaAssets
import Math

enum RigAuthorError: Error { case invalidSource(String) }

/// Bakes original part transforms into model-space vertices and merges by material.
/// Bone-like surfaces stay rigid; clothing and spine use two-joint transition weights.
enum MeshSkinning {
    struct Bucket {
        var mesh = ProceduralMeshData()
        var joints: [SIMD4<UInt16>] = []
        var weights: [SIMD4<Float>] = []
    }

    static func make(_ source: GLTFImportResult) throws -> [ProceduralNode] {
        var parents = [Int?](repeating: nil, count: source.nodes.count)
        for (index, node) in source.nodes.enumerated() {
            for child in node.children { parents[child] = index }
        }
        var globals = [Transform3D](repeating: .identity, count: source.nodes.count)
        var buckets = [Int: Bucket]()
        for (index, node) in source.nodes.enumerated() {
            if let parent = parents[index] {
                guard parent < index else { throw RigAuthorError.invalidSource("Expected the procedural model's parent-first hierarchy") }
                globals[index] = globals[parent] * node.transform
            } else {
                globals[index] = node.transform
            }
            guard let mesh = node.meshIndex else { continue }
            var ancestry = [node.name ?? ""]
            var parent = parents[index]
            while let current = parent { ancestry.append(source.nodes[current].name ?? ""); parent = parents[current] }
            for primitive in source.meshes[mesh].primitives {
                guard primitive.mode == .triangles, let material = primitive.materialIndex,
                    let positions = primitive.attributes[.position]?.vector3Values(),
                    let normals = primitive.attributes[.normal]?.vector3Values(),
                    let uvs = primitive.attributes[.texCoord(0)]?.vector2Values(), let indices = primitive.indices
                else { throw RigAuthorError.invalidSource("Expected indexed, textured-coordinate triangle geometry") }
                var bucket = buckets[material] ?? Bucket()
                let offset = UInt32(bucket.mesh.positions.count)
                let inverse = globals[index].inverse
                // Explicit inverse transpose: the inverse's columns become the normal matrix's rows.
                let normalTransform = Transform3D(rows: [inverse.x, inverse.y, inverse.z, inverse.w])
                for vertex in positions.indices {
                    let p = positions[vertex]
                    let world = globals[index] * Vector4(p.x, p.y, p.z, 1)
                    let n = normals[vertex]
                    let transformed = normalTransform * Vector4(n.x, n.y, n.z, 0)
                    let normal = Vector3(transformed.x, transformed.y, transformed.z).normalized
                    let position = SIMD3(world.x, world.y, world.z)
                    let binding = try influences(path: ancestry, position: position)
                    bucket.mesh.positions.append(position)
                    bucket.mesh.normals.append(normal.simd)
                    bucket.mesh.uvs.append(SIMD2(uvs[vertex].x, uvs[vertex].y))
                    bucket.joints.append(binding.0)
                    bucket.weights.append(binding.1)
                }
                bucket.mesh.indices.append(contentsOf: indices.map { $0 + offset })
                buckets[material] = bucket
            }
        }
        return buckets.keys.sorted().compactMap { material in
            guard let bucket = buckets[material] else { return nil }
            var node = ProceduralNode(name: "Skinned material \(material)", mesh: bucket.mesh)
            node.parent = 0
            node.material = material
            node.skinning = .init(skin: 0, joints: bucket.joints, weights: bucket.weights)
            return node
        }
    }

    private static func influences(path: [String], position p: SIMD3<Float>) throws -> (SIMD4<UInt16>, SIMD4<Float>) {
        let name = path.first ?? ""
        if path.contains("Broken sword") { return bind(.leftHand) }
        if path.contains("Round shield") { return bind(.rightHand) }
        if path.contains("Lower jaw") { return bind(.jaw) }
        if path.contains("Head") { return bind(.head) }
        for left in [true, false] {
            if path.contains(left ? "Left leg" : "Right leg") {
                if ["Shorts leg", "Leather cuff"].contains(name) { return bind(left ? .leftHip : .rightHip) }
                if ["Shin", "Knee"].contains(name) { return bind(left ? .leftKnee : .rightKnee) }
                return bind(left ? .leftAnkle : .rightAnkle)
            }
            if path.contains(left ? "Left arm" : "Right arm") {
                if ["Shoulder", "Humerus"].contains(name) { return bind(left ? .leftShoulder : .rightShoulder) }
                if name == "Hand" { return bind(left ? .leftHand : .rightHand) }
                return bind(left ? .leftElbow : .rightElbow)
            }
        }
        if path.contains("Terracotta neckerchief") || name == "Spine" || name == "Sternum" {
            return blend(.spine, .chest, (p.y - 0.63) / 0.28)
        }
        if path.contains("Torso") {
            if p.y < 0.58 { return bind(.spine) }
            return bind(.chest)
        }
        if path.contains("Pelvis and belt") {
            if name == "Dark shorts" {
                let amount = min(1, max(0, (0.43 - p.y) / 0.14)) * min(1, abs(p.x) / 0.11)
                return blend(.hips, p.x < 0 ? .leftHip : .rightHip, amount)
            }
            return bind(.hips)
        }
        throw RigAuthorError.invalidSource("No semantic weight rule for \(path.joined(separator: "/"))")
    }

    private static func bind(_ joint: Joint) -> (SIMD4<UInt16>, SIMD4<Float>) {
        (SIMD4(UInt16(joint.rawValue), 0, 0, 0), SIMD4(1, 0, 0, 0))
    }

    private static func blend(_ first: Joint, _ second: Joint, _ amount: Float) -> (SIMD4<UInt16>, SIMD4<Float>) {
        let value = min(1, max(0, amount))
        return (SIMD4(UInt16(first.rawValue), UInt16(second.rawValue), 0, 0), SIMD4(1 - value, value, 0, 0))
    }
}
