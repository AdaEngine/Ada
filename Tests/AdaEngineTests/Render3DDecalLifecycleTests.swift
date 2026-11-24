#if os(macOS) || os(Windows) || os(Linux)
import AdaAnimation
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
@testable import AdaScene
import AdaTransform
import AdaUtils
import Math
import Testing

extension Render3DGPUTests.DecalProjection {
    @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
    func morphBeforeSkinPlacementAndDrawingAgree() async throws {
        let scene = try await Render3DDebugViewGPUTests.makeScene()
        for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
        let cube = Mesh.generateCube(renderDevice: scene.device)
        var descriptor = try #require(cube.models.first?.parts.first?.meshDescriptor)
        let count = descriptor.positions.count
        descriptor[MeshDescriptor.jointIndices] = MeshBuffer(Array(repeating: Vector4.zero, count: count))
        descriptor[MeshDescriptor.jointWeights] = MeshBuffer(Array(repeating: Vector4(1, 0, 0, 0), count: count))
        var models = Mesh.generate(from: [descriptor], renderDevice: scene.device).models
        models[0].parts[0].morphTargets = MorphTargetSet(
            positionDeltas: [Array(repeating: Vector3(0.55, 0, 0), count: count)],
            normalDeltas: [[]],
            tangentDeltas: [[]],
            vertexCount: count
        )
        try #require(models[0].parts[0].morphTargets != nil)
        let mesh = Mesh(models: models)
        let material = PBRMaterial()
        material.baseColorFactor = [0.5, 0.5, 0.5, 1]
        let receiver = scene.app.main.spawn("Morphing decal receiver") {
            Mesh3DComponent(mesh: mesh, materials: [material])
            MorphWeights3DComponent(weights: [1])
            Transform(position: [0, 0.65, 0])
        }
        let pose = SkeletalJointPose(rotation: Quat.euler([0, 0, .pi / 2]))
        let rig = try SkeletalRig(nodes: [
            .init(parentIndex: nil, restPose: SkeletalJointPose(), restMatrix: .identity),
            .init(parentIndex: nil, restPose: pose, restMatrix: Transform(rotation: pose.rotation).matrix),
        ])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        let skin = GLTFImportResult.Skin(name: nil, joints: [1], skeletonRootIndex: nil, inverseBindMatrices: [.identity])
        var binding = SkinnedMesh3DComponent(modelRoot: receiver.id, meshNodeIndex: 0, skin: skin)
        binding.updateMatrices(using: player)
        receiver.components[SkinnedMesh3DComponent.self] = binding
        let base = try await scene.render(.depth)
        let bentPoint = Vector3(0, 1.2, -0.5)
        let projector = Decal3D.Projector(
            transform: Transform(rotation: Quat.euler([0, .pi, 0]), position: bentPoint).matrix,
            size: [0.22, 0.22, 0.2]
        )
        let handle = try Decal3D.place(on: receiver, projector: projector, appearance: Self.redSticker)
        let marked = try await scene.render(.albedo)
        let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
        #expect(try Self.isRed(at: bentPoint, in: marked, camera: camera))
        #expect(try await scene.render(.depth).data == base.data)
        receiver.components[MorphWeights3DComponent.self] = MorphWeights3DComponent(weights: [0])
        let restoredPose = try await scene.render(.albedo)
        #expect(try Self.isRed(at: [0, 0.65, -0.5], in: restoredPose, camera: camera))
        try Decal3D.remove(handle, from: receiver)
    }

    @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
    func coversLODReplacementOcclusionAndReceiverRemoval() async throws {
        let scene = try await Render3DDebugViewGPUTests.makeScene()
        for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
        let cube = Mesh.generateCube(renderDevice: scene.device)
        let alternative = Mesh.generateCube(size: [0.8, 0.8, 1], renderDevice: scene.device)
        let material = PBRMaterial()
        material.baseColorFactor = [0.4, 0.4, 0.4, 1]
        let receiver = scene.app.main.spawn("LOD decal receiver") {
            Mesh3DComponent(mesh: cube, materials: [material])
            MeshLOD3DComponent(alternatives: [alternative], screenThresholds: [0.99], hysteresis: 0)
            Transform(position: [-0.65, 0.65, 0])
        }
        let point = Vector3(-0.65, 0.65, -0.5)
        let projector = Decal3D.Projector(
            transform: Transform(rotation: Quat.euler([0, .pi, 0]), position: point).matrix,
            size: [0.25, 0.25, 0.2]
        )
        let handle = try Decal3D.place(on: receiver, projector: projector, appearance: Self.redSticker)
        let first = try await scene.render(.albedo)
        let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
        #expect(try Self.isRed(at: point, in: first, camera: camera))

        let clone = receiver.copy()
        clone.components[Transform.self] = Transform(position: [0.65, 0.65, 0])
        scene.app.main.addEntity(clone)
        let replacement = Mesh.generateCube(size: [0.55, 0.55, 1], renderDevice: scene.device)
        receiver.components[MeshLOD3DComponent.self] = MeshLOD3DComponent(alternatives: [replacement], screenThresholds: [0.99], hysteresis: 0)
        let lodSwitch = try await scene.render(.albedo)
        #expect(try Self.isRed(at: point, in: lodSwitch, camera: camera))
        #expect(try !Self.isRed(at: [0.65, 0.65, -0.5], in: lodSwitch, camera: camera))

        let cover = scene.app.main.spawn("Occluder") {
            Mesh3DComponent(mesh: cube, materials: [material])
            Transform(position: [-0.65, 0.65, -0.9])
        }
        let occluded = try await scene.render(.albedo)
        #expect(try !Self.isRed(at: point, in: occluded, camera: camera))
        scene.app.main.removeEntity(cover.id)
        receiver.components[Visibility.self] = .hidden
        let hidden = try await scene.render(.albedo)
        #expect(try !Self.isRed(at: point, in: hidden, camera: camera))
        receiver.components[Visibility.self] = .visible
        let revealed = try await scene.render(.albedo)
        #expect(try Self.isRed(at: point, in: revealed, camera: camera))
        let turned = Transform(rotation: Quat.euler([0, 0.85, 0]), position: [-0.65, 0.65, 0])
        receiver.components[Transform.self] = turned
        let tilted = try await scene.render(.albedo)
        let tiltedPoint = (turned.matrix * Vector4(0, 0, -0.5, 1)).xyz
        #expect(try Self.isRed(at: tiltedPoint, in: tilted, camera: camera))

        scene.app.main.removeEntity(receiver.id)
        _ = try await scene.render(.albedo)
        #expect(scene.app.main.getResource(Decal3DStorage.self)?.receivers.isEmpty == true)
        #expect(throws: Decal3D.PlacementError.staleHandle) {
            try Decal3D.remove(handle, from: clone)
        }
    }

    private static var redSticker: Decal3D.Appearance {
        .init(color: Image(width: 1, height: 1, color: Color(1, 0, 0, 1)))
    }

    private static func isRed(at point: Vector3, in image: Image, camera: Transform3D) throws -> Bool {
        let clip = camera * Vector4(point, 1)
        let x = Int((0.5 + 0.5 * clip.x / clip.w) * Float(image.width))
        let y = Int((0.5 - 0.5 * clip.y / clip.w) * Float(image.height))
        try #require((0..<image.width).contains(x) && (0..<image.height).contains(y))
        let pixel = image.getPixel(x: x, y: y)
        return pixel.red > 0.8 && pixel.green < 0.15
    }
}
#endif
