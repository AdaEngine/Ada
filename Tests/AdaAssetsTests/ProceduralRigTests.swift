import Foundation
import Math
import Testing
@testable import AdaAssets

@Suite("Procedural rig export")
struct ProceduralRigTests {
    private func model() -> ProceduralModel {
        var root = ProceduralNode(name: "Armature")
        root.translation = [0, 1, 0]
        var joint = ProceduralNode(name: "Joint")
        joint.parent = 0
        joint.translation = [0, 1, 0]
        var mesh = ProceduralNode(name: "Body", mesh: ProceduralGeometry.box(width: 1, height: 1, depth: 1))
        let count = mesh.mesh?.positions.count ?? 0
        mesh.skinning = .init(skin: 0, joints: Array(repeating: [0, 1, 0, 0], count: count), weights: Array(repeating: [0.25, 0.75, 0, 0], count: count))
        let first = SIMD16<Float>(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1)
        var second = first
        second[13] = -2
        let skin = ProceduralSkin(name: "Two joints", skeletonRoot: 0, joints: [0, 1], inverseBindMatrices: [first, second])
        let animation = ProceduralAnimation(name: "Walk", tracks: [.init(node: 1, path: .rotation, times: [0, 0.5, 1],
                                                                       values: [[0, 0, 0, 1], [0, 0.70710677, 0, 0.70710677], [0, 0, 0, 1]])])
        return ProceduralModel(materials: [.init(name: "Bone")], nodes: [root, joint, mesh], skins: [skin], animations: [animation])
    }

    @Test("A real native import preserves palette order, bind matrices, weights and clip channels")
    func roundTrip() throws {
        let data = try GLBWriter().encode(model())
        let imported = try NativeGLTFLoader().load(data: data)
        let skin = try #require(imported.skins.first)
        #expect(skin.joints == [0, 1] && skin.skeletonRootIndex == 0)
        #expect(skin.inverseBindMatrices[0].w.y == -1)
        #expect(skin.inverseBindMatrices[1].w.y == -2)
        #expect(imported.nodes[2].skinIndex == 0)
        let binding = try #require(imported.meshes.first?.primitives.first?.skinning)
        #expect(binding.jointIndices.allSatisfy { $0 == SIMD4(0, 1, 0, 0) })
        #expect(binding.weights.allSatisfy { $0 == Vector4(0.25, 0.75, 0, 0) })
        let clip = try #require(imported.animations.first)
        #expect(clip.name == "Walk" && clip.duration == 1)
        #expect(clip.channels[0].nodeIndex == 1 && clip.channels[0].path == .rotation)
        #expect(clip.samplers[0].times == [0, 0.5, 1])
        // At rest both matrix products are identity, so blending cannot move the original mesh.
        let globalRoot = imported.nodes[0].transform
        let globalChild = globalRoot * imported.nodes[1].transform
        #expect(globalRoot * skin.inverseBindMatrices[0] == .identity)
        #expect(globalChild * skin.inverseBindMatrices[1] == .identity)
    }

    @Test("Skinned and scale-animated leaf transforms are not baked into the mesh")
    func preservesMeshSpace() throws {
        var source = model()
        source.nodes[2].scale = [2, 1, 3]
        let baked = source.bakingLeafScales()
        #expect(baked.nodes[2].scale == [2, 1, 3])
        #expect(baked.nodes[2].mesh == source.nodes[2].mesh)
        source.nodes[2].skinning = nil
        source.animations[0].tracks.append(.init(node: 2, path: .scale, times: [0, 1], values: [[2, 1, 3, 0], [1, 1, 1, 0]]))
        #expect(source.bakingLeafScales().nodes[2].scale == [2, 1, 3])
        let imported = try NativeGLTFLoader().load(data: GLBWriter().encode(source))
        #expect(imported.nodes[2].restPose?.scale == Vector3(2, 1, 3))
    }

    @Test("Invalid palettes, root ancestry and bind matrices are rejected", arguments: 0..<5)
    func invalidSkin(fault: Int) {
        var source = model()
        switch fault {
        case 0: source.skins[0].joints = [0, 0]
        case 1: source.skins[0].skeletonRoot = 1
        case 2: source.skins[0].inverseBindMatrices.removeLast()
        case 3: source.skins[0].inverseBindMatrices[0][3] = 1
        default: source.skins[0].inverseBindMatrices[0][0] = .nan
        }
        #expect(throws: GLBWritingError.invalidSkin(index: 0)) { try GLBWriter().encode(source) }
    }

    @Test("Bad weights, mismatched counts and invalid zero-weight palette slots fail before writing", arguments: 0..<6)
    func invalidWeights(fault: Int) {
        var source = model()
        var binding = source.nodes[2].skinning ?? .init(skin: 0, joints: [], weights: [])
        switch fault {
        case 0: binding.weights[0] = .zero
        case 1: binding.weights[0] = [0.5, 0.75, 0, 0]
        case 2: binding.weights[0] = [.nan, 1, 0, 0]
        case 3: binding.joints[0][3] = 2
        case 4: binding.weights.removeLast()
        default: binding.skin = 1
        }
        source.nodes[2].skinning = binding
        #expect(throws: GLBWritingError.invalidSkinning(node: 2)) { try GLBWriter().encode(source) }
    }

    @Test("Invalid key times, targets, duplicate channels and quaternions fail before writing", arguments: 0..<5)
    func invalidTracks(fault: Int) {
        var source = model()
        switch fault {
        case 0: source.animations[0].tracks[0].times = [0, 0, 1]
        case 1: source.animations[0].tracks[0].node = 3
        case 2: source.animations[0].tracks.append(source.animations[0].tracks[0])
        case 3: source.animations[0].tracks[0].values[0] = [0, 0, 0, 2]
        default: source.animations[0].tracks[0].values.removeLast()
        }
        #expect(throws: GLBWritingError.invalidAnimation(index: 0)) { try GLBWriter().encode(source) }
    }
}
