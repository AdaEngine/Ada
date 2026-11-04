import AdaAssets
import Foundation
import Gravity
import Math

/// Native storage and bounded bulk operations exposed to an interpreted model recipe.
/// Joint placement, weight rules and animation algorithms remain in AdaScript; this type only assembles their data.
final class AdaScriptModelRigBuilder {
    private struct Part {
        let mesh: ProceduralMeshData
    }
    private struct Joint {
        let name: String
        let parent: Int
        let local: SIMD3<Float>
        let world: SIMD3<Float>
    }
    private final class Binding {
        var joints: [SIMD4<UInt16>]
        var weights: [SIMD4<Float>]
        init(count: Int, joint: Int) {
            joints = Array(repeating: SIMD4(UInt16(joint), 0, 0, 0), count: count)
            weights = Array(repeating: SIMD4(1, 0, 0, 0), count: count)
        }
    }
    private struct Target: Hashable {
        let joint: Int
        let path: ProceduralAnimation.Track.Path
    }
    private final class Keys {
        var times: [Float] = []
        var values: [SIMD4<Float>] = []
    }
    private struct Clip {
        let name: String
        var tracks: [Target: Keys] = [:]
    }
    private struct Bucket {
        var mesh = ProceduralMeshData()
        var joints: [SIMD4<UInt16>] = []
        var weights: [SIMD4<Float>] = []
    }

    private var parts: [Int: Part] = [:]
    private var joints: [Joint] = []
    private var bindings: [Int: Binding] = [:]
    private var clips: [Clip] = []
    private var keyCount = 0

    init(nodes: [ProceduralNode]) throws {
        var worlds = [Transform3D](repeating: .identity, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            let p = node.translation, r = node.rotation, s = node.scale
            let local = Transform3D(translation: Vector3(p.x, p.y, p.z), rotation: Quat(x: r.x, y: r.y, z: r.z, w: r.w), scale: Vector3(s.x, s.y, s.z))
            if let parent = node.parent {
                guard parent >= 0, parent < index else { throw invalid("Invalid geometry parent") }
                worlds[index] = worlds[parent] * local
            } else { worlds[index] = local }
            guard var mesh = node.mesh else { continue }
            let world = worlds[index]
            guard world.determinant.isFinite, abs(world.determinant) > 1e-12 else { throw invalid("Cannot rig singular or nonfinite geometry") }
            let inverse = world.inverse
            let normal = Transform3D(rows: [inverse.x, inverse.y, inverse.z, inverse.w])
            for vertex in mesh.positions.indices {
                let p = mesh.positions[vertex], n = mesh.normals[vertex]
                let moved = world * Vector4(p.x, p.y, p.z, 1)
                let rotated = normal * Vector4(n.x, n.y, n.z, 0)
                let unit = Vector3(rotated.x, rotated.y, rotated.z).normalized
                mesh.positions[vertex] = SIMD3(moved.x, moved.y, moved.z)
                mesh.normals[vertex] = SIMD3(unit.x, unit.y, unit.z)
            }
            guard mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw invalid("Nonfinite rig geometry") }
            parts[index] = Part(mesh: mesh)
        }
    }

    func addJoint(name: String, parent: Int, position: SIMD3<Float>) throws -> Int {
        guard joints.count < 128, !name.isEmpty, name.count <= 64, !joints.contains(where: { $0.name == name }),
            joints.isEmpty ? parent == -1 : joints.indices.contains(parent)
        else { throw invalid("model.joint needs a unique name, an earlier joint parent (-1 for the first root), and at most 128 joints") }
        let world = position + (parent == -1 ? .zero : joints[parent].world)
        joints.append(Joint(name: name, parent: parent, local: position, world: world))
        return joints.count - 1
    }

    func bind(part: Int, joint: Int) throws -> Bool {
        guard let mesh = parts[part]?.mesh, joints.indices.contains(joint) else { throw invalid("model.bind needs a mesh part and a valid joint") }
        bindings[part] = Binding(count: mesh.positions.count, joint: joint)
        return true
    }

    func position(part: Int, vertex: Int, axis: Int) throws -> Double {
        guard let mesh = parts[part]?.mesh, mesh.positions.indices.contains(vertex), (0..<3).contains(axis) else {
            throw invalid("model.vertexPosition needs a mesh part, vertex index and axis 0...2")
        }
        return Double(mesh.positions[vertex][axis])
    }

    func weights(part: Int, vertex: Int, first: Int, firstWeight: Double, second: Int, secondWeight: Double) throws -> Bool {
        guard let binding = bindings[part], binding.weights.indices.contains(vertex), joints.indices.contains(first), joints.indices.contains(second),
            (0...1).contains(firstWeight), (0...1).contains(secondWeight), abs(firstWeight + secondWeight - 1) < 0.0001
        else { throw invalid("model.weights needs a bound vertex, two valid joints and nonnegative weights summing to one") }
        let total = Float(firstWeight + secondWeight)
        binding.joints[vertex] = SIMD4(UInt16(first), UInt16(second), 0, 0)
        binding.weights[vertex] = SIMD4(Float(firstWeight) / total, Float(secondWeight) / total, 0, 0)
        return true
    }

    func addClip(name: String) throws -> Int {
        guard !name.isEmpty, name.count <= 64, !clips.contains(where: { $0.name == name }), clips.count < 32 else {
            throw invalid("model.clip needs a unique nonempty name; at most 32 clips")
        }
        clips.append(Clip(name: name))
        return clips.count - 1
    }

    func key(clip: Int, joint: Int, time: Double, value: SIMD3<Float>, rotation: Bool) throws -> Bool {
        guard clips.indices.contains(clip), joints.indices.contains(joint), time >= 0, time <= 3600, keyCount < 16_384 else {
            throw invalid("Invalid clip/joint/time; model keys are limited to 16384 and one hour")
        }
        let target = Target(joint: joint, path: rotation ? .rotation : .translation)
        let keys = clips[clip].tracks[target] ?? Keys()
        let instant = Float(time)
        guard keys.times.last.map({ instant > $0 }) ?? true else { throw invalid("Key times must strictly increase per joint and channel") }
        keys.times.append(instant)
        keys.values.append(rotation ? ProceduralMath.quaternion(eulerDegrees: value) : SIMD4(value.x, value.y, value.z, 0))
        clips[clip].tracks[target] = keys
        keyCount += 1
        return true
    }

    func finish(_ source: ProceduralModel) throws -> ProceduralModel {
        guard !joints.isEmpty else { throw invalid("The rig has no joints") }
        var nodes = [ProceduralNode(name: source.nodes.first?.name ?? "Rigged model")]
        for joint in joints {
            var node = ProceduralNode(name: joint.name)
            node.parent = joint.parent == -1 ? 0 : joint.parent + 1
            node.translation = joint.local
            nodes.append(node)
        }
        var buckets: [Int: Bucket] = [:]
        for index in source.nodes.indices {
            guard let part = parts[index] else { continue }
            guard let binding = bindings[index] else { throw invalid("Bind every mesh part before export; missing \(source.nodes[index].name)") }
            let material = source.nodes[index].material
            var bucket = buckets[material] ?? Bucket()
            let offset = UInt32(bucket.mesh.positions.count)
            bucket.mesh.positions.append(contentsOf: part.mesh.positions)
            bucket.mesh.normals.append(contentsOf: part.mesh.normals)
            bucket.mesh.uvs.append(contentsOf: part.mesh.uvs)
            bucket.mesh.indices.append(contentsOf: part.mesh.indices.map { $0 + offset })
            bucket.joints.append(contentsOf: binding.joints)
            bucket.weights.append(contentsOf: binding.weights)
            buckets[material] = bucket
        }
        for material in buckets.keys.sorted() {
            guard let bucket = buckets[material] else { continue }
            var node = ProceduralNode(name: "Skinned material \(material)", mesh: bucket.mesh)
            node.parent = 0
            node.material = material
            node.skinning = ProceduralSkinning(skin: 0, joints: bucket.joints, weights: bucket.weights)
            nodes.append(node)
        }
        let skin = ProceduralSkin(name: "AdaScript rig", skeletonRoot: 1, joints: joints.indices.map { $0 + 1 }, inverseBindMatrices: joints.map { joint in
            let p = joint.world
            return SIMD16(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -p.x, -p.y, -p.z, 1)
        })
        let animations = clips.map { clip in
            let targets = clip.tracks.keys.sorted { $0.joint == $1.joint ? $0.path.rawValue < $1.path.rawValue : $0.joint < $1.joint }
            return ProceduralAnimation(name: clip.name, tracks: targets.compactMap { target in
                guard let keys = clip.tracks[target] else { return nil }
                return .init(node: target.joint + 1, path: target.path, times: keys.times, values: keys.values)
            })
        }
        return ProceduralModel(materials: source.materials, nodes: nodes, skins: [skin], animations: animations)
    }

    private func invalid(_ message: String) -> AdaScriptError { .invalidManifest(message) }
}

extension AdaScriptModelRigBuilder {
    func index(_ value: GSValue) throws -> Int {
        let number = try number(value)
        guard number.rounded() == number, abs(number) <= 1_000_000 else { throw AdaScriptError.invalidManifest("Expected an integer index") }
        return Int(number)
    }

    func number(_ value: GSValue) throws -> Double {
        guard let number = value.finiteNumber else { throw AdaScriptError.invalidManifest("Expected a finite number") }
        return number
    }

    func text(_ value: GSValue) throws -> String {
        guard value.isString else { throw AdaScriptError.invalidManifest("Expected a name string") }
        return value.toString
    }

    private func list(_ value: GSValue, count: Int) throws -> [GSValue] {
        guard value.isList, value.toList.count == count else { throw AdaScriptError.invalidManifest("Invalid rig argument packet") }
        return value.toList
    }

    func scriptJoint(_ name: GSValue, _ parent: GSValue, _ position: GSValue) throws -> Int {
        let coordinates = try list(position, count: 3).map(number)
        guard coordinates.allSatisfy({ abs($0) <= 1000 }) else { throw AdaScriptError.invalidManifest("Joint coordinates must be within 1000 meters") }
        return try addJoint(name: text(name), parent: index(parent), position: SIMD3(Float(coordinates[0]), Float(coordinates[1]), Float(coordinates[2])))
    }

    func scriptWeights(_ part: GSValue, _ vertex: GSValue, _ packet: GSValue) throws -> Bool {
        let values = try list(packet, count: 4)
        return try weights(part: index(part), vertex: index(vertex), first: index(values[0]), firstWeight: number(values[1]),
                           second: index(values[2]), secondWeight: number(values[3]))
    }

    func scriptKey(_ clip: GSValue, _ joint: GSValue, _ packet: GSValue, rotation: Bool) throws -> Bool {
        let values = try list(packet, count: 4)
        let coordinates = try values.dropFirst().map(number)
        guard coordinates.allSatisfy({ abs($0) <= (rotation ? 1_000_000 : 1000) }) else { throw AdaScriptError.invalidManifest("Key values exceed the rig limits") }
        return try key(clip: index(clip), joint: index(joint), time: number(values[0]),
                       value: SIMD3(Float(coordinates[0]), Float(coordinates[1]), Float(coordinates[2])), rotation: rotation)
    }
}
