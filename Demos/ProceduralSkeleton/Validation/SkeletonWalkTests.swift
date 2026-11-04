import AdaAnimation
import AdaAssets
import Math
import Testing
@testable import SkeletonRig

@Suite("Skeleton walk acceptance")
struct SkeletonWalkTests {
    private func player() throws -> SkeletalAnimationPlayer {
        let nodes = SkeletonRig.nodes
        let rig = try SkeletalRig(nodes: nodes.map { node in
            let t = node.translation
            let pose = SkeletalJointPose(translation: Vector3(t.x, t.y, t.z))
            return SkeletalRig.Node(parentIndex: node.parent, restPose: pose, restMatrix: pose.matrix, name: node.name)
        })
        let clip = WalkClip.make()
        let tracks = try clip.tracks.map { track in
            try SkeletalAnimationTrack(nodeIndex: track.node, path: track.path == .rotation ? .rotation : .translation,
                                       interpolation: .linear, times: track.times.map(Double.init),
                                       values: track.values.map { Vector4($0.x, $0.y, $0.z, $0.w) })
        }
        return try SkeletalAnimationPlayer(rig: rig, clips: [.init(name: clip.name, tracks: tracks)])
    }

    @Test("Native player loops continuously and leaves the model root in place")
    func loop() throws {
        var player = try player()
        try player.play("Walk", transitionDuration: 0)
        let duration = Double(WalkClip.duration)
        for time in [0.0, 0.17, 0.49, 0.93] {
            player.seek(to: time)
            let first = player.globalTransforms
            player.seek(to: time + duration)
            for index in first.indices {
                let a = first[index], b = player.globalTransforms[index]
                for column in 0..<4 {
                    for row in 0..<4 { #expect(abs(a[column, row] - b[column, row]) < 0.00002) }
                }
            }
            #expect(player.globalTransforms[0] == .identity)
        }
    }

    @Test("Both feet remain flat and above the floor; each alternates stance and swing")
    func contacts() throws {
        var player = try player()
        try player.play("Walk", transitionDuration: 0)
        var raised = [Joint.leftAnkle: Float(0), Joint.rightAnkle: Float(0)]
        for step in 0..<96 {
            player.seek(to: Double(step) / 96 * Double(WalkClip.duration))
            for ankle in [Joint.leftAnkle, .rightAnkle] {
                let matrix = player.globalTransforms[ankle.node]
                let height = matrix.w.y - ankle.position.y
                #expect(height >= -0.001, "Sole must not sink through the floor")
                #expect(height < 0.037, "Swing clearance must stay within the authored range")
                #expect(abs(matrix.y.x) < 0.0001 && abs(matrix.y.z) < 0.0001 && abs(matrix.y.y - 1) < 0.0001, "Foot should stay flat")
                raised[ankle] = max(raised[ankle] ?? 0, height)
            }
            let left = player.globalTransforms[Joint.leftAnkle.node].w.y
            let right = player.globalTransforms[Joint.rightAnkle.node].w.y
            #expect(min(left, right) < 0.121, "At least one planted foot is required")
        }
        #expect((raised[.leftAnkle] ?? 0) > 0.03 && (raised[.rightAnkle] ?? 0) > 0.03)
    }

    @Test("Encoded clip keys and inverse binds survive the native importer")
    func export() throws {
        var mesh = ProceduralNode(name: "Probe", mesh: ProceduralGeometry.box(width: 0.1, height: 0.1, depth: 0.1))
        mesh.parent = 0
        let count = mesh.mesh?.positions.count ?? 0
        mesh.skinning = .init(skin: 0, joints: Array(repeating: [5, 0, 0, 0], count: count), weights: Array(repeating: [1, 0, 0, 0], count: count))
        let model = ProceduralModel(materials: [.init(name: "Probe")], nodes: SkeletonRig.nodes + [mesh],
                                    skins: [SkeletonRig.skin], animations: [WalkClip.make()])
        let imported = try NativeGLTFLoader().load(data: GLBWriter().encode(model))
        #expect(imported.skins.first?.joints.count == 23)
        #expect(imported.animations.first?.samplers.allSatisfy { $0.times.count == 49 } == true)
        let inverse = try #require(imported.skins.first?.inverseBindMatrices[Joint.head.rawValue])
        #expect(abs(inverse.w.y + 1.14) < 0.00001)
    }

    @Test("Baking rotated source geometry preserves outward-facing normals")
    func bakedNormals() throws {
        let root = ProceduralNode(name: "Head")
        var box = ProceduralNode(name: "Rotated skull probe", mesh: ProceduralGeometry.box(width: 1, height: 2, depth: 3))
        box.parent = 0
        box.rotation = ProceduralMath.quaternion(eulerDegrees: [25, 35, 70])
        box.scale = [1, 2, 3]
        let source = ProceduralModel(materials: [.init(name: "Bone")], nodes: [root, box])
        let imported = try NativeGLTFLoader().load(data: GLBWriter().encode(source))
        let baked = try MeshSkinning.make(imported)
        let mesh = try #require(baked.first?.mesh)
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            let corners = (0..<3).map { Int(mesh.indices[start + $0]) }
            let p = mesh.positions[corners[0]], q = mesh.positions[corners[1]], r = mesh.positions[corners[2]]
            let u = q - p, v = r - p
            let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
            let face = cross / (cross * cross).sum().squareRoot()
            for index in corners { #expect((face * mesh.normals[index]).sum() > 0.999) }
        }
    }
}
