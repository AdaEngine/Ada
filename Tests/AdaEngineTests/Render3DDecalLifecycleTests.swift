#if os(macOS) || os(Windows) || os(Linux)
import AdaAnimation
@_spi(Internal) import AdaApp
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
@_spi(Scripting) @testable import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests.DecalProjection {
    @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
    func authoredAndQueuedDecalsComposeInStableOrder() async throws {
        let scene = try await Render3DDebugViewGPUTests.makeScene()
        let world = scene.app.main
        for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent("AdaDecals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: assets) }
        let red = Image(width: 4, height: 4, color: Color(1, 0, 0, 1))
        let green = Image(width: 4, height: 4, color: Color(0, 1, 0, 1))
        try red.writePNG(to: assets.appendingPathComponent("Red.png"))
        try green.writePNG(to: assets.appendingPathComponent("Green.png"))
        await scene.app.withExecutionContext {
            await AssetsManager.setProjectDirectories(ProjectDirectories(source: assets, assetsDirectory: assets))
        }
        let owner = world.spawn("Decal order") { Transform(position: [0, 0.65, 0]) }
        let reference = Model3DSource(source: "@res://Static.glb")
        owner.components += reference
        let model = ModelAsset3D(
            nodes: [.init(name: "Surface", transform: .identity, meshIndex: 0, children: [])],
            meshes: [.generateCube(renderDevice: scene.device)],
            materials: [PBRMaterial()],
            scenes: [[0]],
            defaultScene: 0
        )
        let root = try reference.instantiate(model, in: world, under: owner)
        let receiver = try #require(root.children.first)
        #expect(receiver.components[ModelNode3DComponent.self]?.nodeIndex == 0)
        let localPoint = Vector3(0, 0, -0.5)
        let point = localPoint + Vector3(0, 0.65, 0)
        let direction = Vector3(0, 0, -1)
        let size = Vector3(0.4, 0.4, 0.15)
        let frame = try #require(Decal3D.Projector.surfaceFrame(point: point, normal: direction))
        let queue = try #require(world.getResource(Decal3DCommands.self))
        let place = queue.enqueue(.place(receiver.id, .init(transform: frame, size: size), .init(color: "@res://Red.png")))
        var outcome: Decal3DCommands.Outcome?
        for _ in 0..<120 {
            try await scene.app.update()
            outcome = queue.takeResult(place)
            if outcome != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let result = try #require(outcome)
        try #require(result.errorCode.isEmpty, "\(result.message)")
        let localFrame = try #require(Decal3D.Projector.surfaceFrame(point: localPoint, normal: direction))
        let entry = Decal3DSource.Entry(
            node: .init(source: reference.source, index: 0, name: "Surface"),
            localFrame: localFrame,
            size: size,
            images: .init(color: "@res://Green.png")
        )
        let authored = Decal3DSource(entries: [entry])
        let data = try JSONEncoder().encode(authored)
        owner.components += try JSONDecoder().decode(Decal3DSource.self, from: data)
        for _ in 0..<120 {
            try await scene.app.update()
            if world.getResource(Decal3DStorage.self)?.receivers[receiver.id]?.entries.count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(world.getResource(Decal3DStorage.self)?.receivers[receiver.id]?.entries.count == 2)
        let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
        let above = try await scene.render(.albedo)
        #expect(try Self.isRed(at: point, in: above, camera: camera))
        let removal = queue.enqueue(.remove(receiver.id, result.value))
        var greenVisible = false
        for _ in 0..<60 {
            let below = try await scene.render(.albedo, frames: 1)
            let pixel = try Self.sample(at: point, image: below, camera: camera)
            greenVisible = pixel.green > 0.8 && pixel.red < 0.15
            if greenVisible { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(greenVisible)
        #expect(queue.takeResult(removal)?.errorCode.isEmpty == true)
    }

    @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
    func persistedLocalProjectorWorksAfterNonuniformParentScaling() async throws {
        let scene = try await Render3DDebugViewGPUTests.makeScene()
        let parent = scene.app.main.spawn("Scaled parent") {
            Transform(scale: [100, 1, 1])
        }
        let receiver = scene.app.main.spawn("Rotated receiver") {
            Mesh3DComponent(mesh: .generateCube(renderDevice: scene.device), materials: [PBRMaterial()])
            Transform(rotation: Quat.euler([0, .pi / 4, 0]))
        }
        parent.addChild(receiver)
        let localFrame = try #require(Decal3D.Projector.surfaceFrame(point: [0, 0, -0.5], normal: [0, 0, -1]))
        let entry = Decal3DSource.Entry(localFrame: localFrame, size: [0.3, 0.3, 0.1], images: .init(color: "@res://Red.png"))
        let handle = try Decal3D.place(
            on: receiver,
            projector: entry.projector(),
            appearance: Self.redSticker,
            part: nil,
            replacing: nil,
            authoredOrder: 0
        )
        #expect(Decal3D.contains(handle, on: receiver))
    }

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
