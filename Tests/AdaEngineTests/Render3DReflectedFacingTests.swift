#if os(macOS)
import AdaAnimation
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
@preconcurrency import Metal
import Testing

@testable import AdaCorePipelines

extension Render3DGPUTests {
    /// Image parity for physically identical geometry, with winding reversed by instance or joint transforms.
    @Suite("3D reflected facing on GPU")
    @MainActor
    struct ReflectedFacing {
        private static func mesh(skinned: Bool, device: RenderDevice) -> Mesh {
            var descriptor = MeshDescriptor(name: "Facing quad")
            descriptor[MeshDescriptor.positions] = MeshBuffer<Vector3>([[-0.4, -0.5, 0], [0.4, -0.5, 0], [-0.4, 0.5, 0], [0.4, 0.5, 0]])
            descriptor[MeshDescriptor.normals] = MeshBuffer<Vector3>(Array(repeating: [0, 0, -1], count: 4))
            descriptor[MeshDescriptor.tangents] = MeshBuffer<Vector4>(Array(repeating: [1, 0, 0, 1], count: 4))
            descriptor[MeshDescriptor.textureCoordinates] = MeshBuffer<Vector2>([[0, 0], [1, 0], [0, 1], [1, 1]])
            descriptor.indicies = [0, 2, 1, 2, 3, 1]
            if skinned {
                descriptor[MeshDescriptor.jointIndices] = MeshBuffer<Vector4>(Array(repeating: .zero, count: 4))
                descriptor[MeshDescriptor.jointWeights] = MeshBuffer<Vector4>(Array(repeating: [1, 0, 0, 0], count: 4))
            }
            return Mesh.generate(from: [descriptor], renderDevice: device)
        }

        private static func skin(for entity: Entity, reflected: Bool) throws -> SkinnedMesh3DComponent {
            let rig = try SkeletalRig(nodes: [
                .init(parentIndex: nil, restPose: nil, restMatrix: .identity),
                .init(parentIndex: nil, restPose: nil, restMatrix: Transform3D(scale: [reflected ? -1 : 1, 1, 1]))
            ])
            var skin = SkinnedMesh3DComponent(
                modelRoot: entity.id, meshNodeIndex: 0,
                skin: .init(name: nil, joints: [1], skeletonRootIndex: 1, inverseBindMatrices: [.identity])
            )
            skin.updateMatrices(using: try SkeletalAnimationPlayer(rig: rig, clips: []))
            return skin
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: [false, true], [false, true])
        func reflectedInstancesPreservePointLighting(skinned: Bool, turnedCamera: Bool) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            try scene.configure {
                $0.ambientOcclusion.isEnabled = false
                $0.imageBasedLighting = nil
                $0.localShadows.isEnabled = false
                $0.tiledLocalLights = false
            }
            var camera = try #require(scene.camera.components[Camera.self])
            camera.backgroundColor = .black
            scene.camera.components[Camera.self] = camera
            let rotation = turnedCamera ? Quat.euler([0, .pi, 0]) : .identity
            scene.camera.components[Transform.self] = Transform(rotation: rotation, position: [0, 0.5, turnedCamera ? 3.4 : -3.4])
            let point = scene.app.main.spawn("Point only") {
                PointLightComponent(radiance: [1, 0.8, 0.6], intensity: 40, castShadows: false, range: 8)
                Transform(position: [0, 1.5, turnedCamera ? 2 : -2])
            }
            let mesh = Self.mesh(skinned: skinned, device: scene.device)
            let material = PBRMaterial()
            material.baseColorFactor = [0.7, 0.5, 0.3, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 0.7
            material.clearcoatFactor = 0.4
            material.clearcoatRoughnessFactor = 0.5
            // A shared mesh/material exercises mixed-sign instance batches, not one uniform per draw.
            let entities = (0..<3).map { index in
                scene.app.main.spawn("Quad \(index)") {
                    Mesh3DComponent(mesh: mesh, materials: [material], castShadows: false, receiveShadows: false)
                    Transform(rotation: rotation, position: [Float(index - 1), 0.5, 0])
                }
            }
            func setReflection(_ reflected: Bool) throws {
                for (index, entity) in entities.enumerated() {
                    var transform = try #require(entity.components[Transform.self])
                    transform.scale = [reflected && index != 1 ? -1 : 1, 1, 1]
                    entity.components[Transform.self] = transform
                    if skinned {
                        // Instance only, joint only, and two reflections (positive combined determinant).
                        entity.components[SkinnedMesh3DComponent.self] = try Self.skin(for: entity, reflected: reflected && index != 0)
                    }
                }
            }
            for doubleSided in [true, false] {
                material.doubleSided = doubleSided
                for normalMapped in [false, true] {
                    // A Y-tilted normal stays physically unchanged under X reflection only with correct tangent handedness.
                    material.normalTexture = normalMapped ? Texture2D(image: Image(width: 1, height: 1, color: Color(red: 0.5, green: 0.25, blue: 1))) : nil
                    try setReflection(false)
                    let positive = try await scene.render(.none)
                    let center = positive.getPixel(x: positive.width / 2, y: positive.height / 2)
                    #expect(center.red > 0.3, "The point-lit baseline must contain bright geometry: \(center).")
                    try setReflection(true)
                    let reflected = try await scene.render(.none)
                    let comparison = GoldenFrame.compare(reflected, positive, tolerance: GoldenFrame.activeTolerance)
                    #expect(comparison.passes(GoldenFrame.activeTolerance), "Reflection changed lighting: skinned=\(skinned), turned=\(turnedCamera), doubleSided=\(doubleSided), normalMapped=\(normalMapped), \(comparison).")
                }
            }
            // Distinguish real local lighting from the renderer's small ambient fallback.
            var light = try #require(point.components[PointLightComponent.self])
            light.intensity = 0
            point.components[PointLightComponent.self] = light
            let unlit = try await scene.render(.none)
            #expect(unlit.getPixel(x: unlit.width / 2, y: unlit.height / 2).red < 0.3)
        }

        /// Read private HDR targets through the engine queue; ordinary Image readback only supports 8-bit pixels.
        private static func readback(_ texture: Texture, scene: DebugViews.Scene, bytesPerPixel: Int) async throws -> (Data, Int) {
            let native = try #require(MetalInterop.texture(texture))
            let rowBytes = (native.width * bytesPerPixel + 255) & ~255
            let buffer = try #require(native.device.makeBuffer(length: rowBytes * native.height, options: .storageModeShared))
            let queue = try #require(scene.queue)
            let command = try #require(queue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(
                from: native, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: native.width, height: native.height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * native.height
            )
            blit.endEncoding()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            return (unsafe Data(bytes: buffer.contents(), count: rowBytes * native.height), rowBytes)
        }

        @Test(.enabled(if: GoldenFrame.activeBackend == .metal))
        func reflectedSingleSidedCasterPreservesItsShadowDepth() async throws {
            let scene = try await DebugViews.makeScene()
            for entity in scene.sphereEntities { scene.app.main.removeEntity(entity) }
            try scene.configure { $0.ambientOcclusion.isEnabled = false }
            let caster = scene.app.main.spawn("Single-sided caster") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.8, 1.4, 0.8], renderDevice: scene.device), materials: [PBRMaterial()])
                Transform(position: [0, 0.7, 0])
            }
            func depths() async throws -> [Float] {
                _ = try await scene.render(.none)
                let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                let shadow = try #require(world.getResource(DirectionalShadow3D.self))
                let texture = try #require(shadow.colorTexture)
                let (data, rowBytes) = try await Self.readback(texture, scene: scene, bytesPerPixel: 16)
                return unsafe data.withUnsafeBytes { bytes in
                    (0..<texture.size.height).flatMap { y in
                        (0..<texture.size.width).map { x in bytes.loadUnaligned(fromByteOffset: y * rowBytes + x * 16, as: Float.self) }
                    }
                }
            }
            let positive = try await depths()
            caster.components[Transform.self] = Transform(scale: [-1, 1, 1], position: [0, 0.7, 0])
            let reflected = try await depths()
            let differences = zip(positive, reflected).filter { abs($0 - $1) > 0.00001 }.count
            #expect(differences < positive.count / 10_000, "The same physical caster must keep its shadow depth: \(differences) texels differ.")
            caster.components[Visibility.self] = .hidden
            let hidden = try await depths()
            #expect(zip(positive, hidden).filter { abs($0 - $1) > 0.00001 }.count > 20, "The caster must actually contribute depth to the shadow map.")
        }

        @Test(.enabled(if: GoldenFrame.activeBackend == .metal))
        func reflectedSingleSidedMeshPreservesItsMotionVector() async throws {
            var motion: [Float] = []
            for reflected in [false, true] {
                let scene = try await DebugViews.makeScene(temporalRenderScale: 0.67)
                try #require(scene.device.supportsTemporalUpscaling)
                for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                    scene.app.main.removeEntity(entity)
                }
                let entity = scene.app.main.spawn("Moving single-sided quad") {
                    Mesh3DComponent(mesh: Self.mesh(skinned: false, device: scene.device), materials: [PBRMaterial()])
                    Transform(scale: [reflected ? -1 : 1, 1, 1], position: [0, 0.5, 0])
                }
                _ = try await scene.render(.none)
                var transform = try #require(entity.components[Transform.self])
                transform.position.x = 0.12
                entity.components[Transform.self] = transform
                _ = try await scene.render(.none, frames: 1)
                let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                let target = try #require(world.getEntities().compactMap { $0.components[RenderViewTarget.self] }.first)
                let texture = try #require(target.temporalMotionTexture)
                let (data, rowBytes) = try await Self.readback(texture, scene: scene, bytesPerPixel: 8)
                let bits = unsafe data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: texture.size.height / 2 * rowBytes + texture.size.width / 2 * 8, as: UInt16.self) }
                motion.append(Float(Float16(bitPattern: bits)))
            }
            #expect(abs(motion[0]) > 0.005, "The moving quad must write a real motion vector.")
            #expect(abs(motion[1] - motion[0]) < 0.0001, "Reflection must preserve physical motion: \(motion).")
        }
    }
}
#endif
