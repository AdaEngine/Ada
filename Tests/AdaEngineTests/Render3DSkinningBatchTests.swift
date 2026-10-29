import AdaAnimation
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Exact skinned instance batching")
    @MainActor
    struct SkinningBatches {
        @Test
        func oldShadowSettingsDecodeWithoutChangingQuality() throws {
            let settings = try JSONDecoder().decode(ShadowSettings3D.self,
                from: Data(#"{"cascadeCount":3,"splitLambda":0.85}"#.utf8))
            #expect(settings.resolution == 1024)
            #expect(settings.cascadeCount == 3 && settings.splitLambda == 0.85)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func shadowAtlasTracksResolutionAndCascadeCount() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.shadows = ShadowSettings3D(cascadeCount: 3, resolution: 2048) }
            _ = try await scene.render(.none)
            let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let shadow = try #require(render.getResource(DirectionalShadow3D.self))
            #expect(shadow.colorTexture?.size == SizeInt(width: 6144, height: 2048))
            try scene.configure { $0.shadows = ShadowSettings3D(cascadeCount: 1, resolution: 1024) }
            _ = try await scene.render(.none)
            #expect(render.getResource(DirectionalShadow3D.self)?.colorTexture?.size == SizeInt(width: 1024, height: 1024))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func packedBuffersKeepExactPosesHistoryAndOverflow() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            var uniforms = Skinning3DUniforms()
            let a = scene.app.main.spawn().id, b = scene.app.main.spawn().id, overflow = scene.app.main.spawn().id
            let first = [Transform3D](repeating: Transform3D(translation: [1, 2, 3]), count: Skinning3DUniforms.maximumJoints / 2)
            let second = [Transform3D](repeating: Transform3D(translation: [-3, 4, 5]), count: Skinning3DUniforms.maximumJoints / 2)
            uniforms.beginFrame(device: scene.device)
            let leftValue = uniforms.writePacked(first, for: a, device: scene.device, revision: nil)

            let left = try #require(leftValue)
            let rightValue = uniforms.writePacked(second, for: b, device: scene.device, revision: nil)

            let right = try #require(rightValue)
            let otherValue = uniforms.writePacked([.identity], for: overflow, device: scene.device, revision: nil)

            let other = try #require(otherValue)
            uniforms.finishPackedWrites()
            #expect(ObjectIdentifier(left) == ObjectIdentifier(right))
            #expect(ObjectIdentifier(left) != ObjectIdentifier(other))
            #expect(uniforms.packedOffset(for: a) == 0 && uniforms.packedOffset(for: b) == Skinning3DUniforms.maximumJoints / 2)
            #expect(Self.matrices(try await left.readData()) == first + second)
            uniforms.beginFrame(device: scene.device)
            _ = uniforms.writePacked(first, for: b, device: scene.device, revision: nil)
            let changedValue = uniforms.writePacked(second, for: a, device: scene.device, revision: nil)

            let changed = try #require(changedValue)
            uniforms.finishPackedWrites()
            #expect(uniforms.packedOffset(for: b) == 0 && uniforms.packedOffset(for: a) == Skinning3DUniforms.maximumJoints / 2)
            #expect(Self.matrices(try await changed.readData()) == first + second)
            let previous = try #require(uniforms.previousBuffer(for: a))
            #expect(Self.matrices(try await previous.readData()) == second + first)
            // A material can leave a packed batch (for example, atmosphere mode).
            // Its individual upload must not overwrite the other instance's page.
            let sharedBytes = try await changed.readData()
            let separate = uniforms.write(first, for: a, device: scene.device)
            let separateBuffer = try #require(separate)
            #expect(ObjectIdentifier(separateBuffer) != ObjectIdentifier(changed))
            #expect(uniforms.packedOffset(for: a) == 0)
            #expect(try await changed.readData() == sharedBytes)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func batchedSkinPosesMatchStaticGeometryAndShadows() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
            let plain = Mesh.generateCube(renderDevice: scene.device)
            let part = try #require(plain.models.first?.parts.first)
            var descriptor = part.meshDescriptor
            let count = descriptor.positions.elements.count
            descriptor[MeshDescriptor.jointIndices] = MeshBuffer(Array(repeating: Vector4.zero, count: count))
            descriptor[MeshDescriptor.jointWeights] = MeshBuffer(Array(repeating: Vector4(1, 0, 0, 0), count: count))
            let skinned = Mesh.generate(from: [descriptor], renderDevice: scene.device)
            let material = PBRMaterial()
            material.baseColorFactor = [0.65, 0.3, 0.2, 1]
            let shifts: [Vector3] = [[0.2, 0, 0], [-0.2, 0.25, 0]]
            var entities: [Entity] = []
            for index in shifts.indices {
                let entity = scene.app.main.spawn("Independent pose") {
                    Mesh3DComponent(mesh: skinned, materials: [material])
                    Transform(position: [index == 0 ? -0.7 : 0.7, 0.6, 0])
                }
                let rig = try SkeletalRig(nodes: [
                    .init(parentIndex: nil, restPose: SkeletalJointPose(), restMatrix: .identity),
                    .init(parentIndex: nil, restPose: SkeletalJointPose(translation: shifts[index]), restMatrix: Transform3D(translation: shifts[index])),
                ])
                let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
                let skin = GLTFImportResult.Skin(name: nil, joints: [1], skeletonRootIndex: nil, inverseBindMatrices: [.identity])
                var binding = SkinnedMesh3DComponent(modelRoot: entity.id, meshNodeIndex: 0, skin: skin)
                binding.updateMatrices(using: player)
                entity.components[SkinnedMesh3DComponent.self] = binding
                entities.append(entity)
            }
            let batch = try await scene.render(.none)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let sources = try #require(renderWorld.getResource(ExtractedMesh3DSources.self)).meshes.filter { entities.map(\.id).contains($0.entity) }
            #expect(sources.count == 2 && sources.map(\.skinningOffset).sorted() == [0, 1])
            for (index, entity) in entities.enumerated() {
                entity.components[SkinnedMesh3DComponent.self] = nil
                var mesh = try #require(entity.components[Mesh3DComponent.self]); mesh.mesh = plain
                entity.components[Mesh3DComponent.self] = mesh
                var pose = try #require(entity.components[Transform.self]); pose.position += shifts[index]
                entity.components[Transform.self] = pose
            }
            let reference = try await scene.render(.none)
            #expect(GoldenFrame.compare(batch, reference, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance),
                    "Packing independent poses must preserve both visible geometry and cast shadows.")
        }

        private static func matrices(_ data: Data) -> [Transform3D] {
            data.withUnsafeBytes { bytes in
                (0 ..< data.count / MemoryLayout<Transform3D>.stride).map {
                    bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Transform3D>.stride, as: Transform3D.self)
                }
            }
        }
    }
}
