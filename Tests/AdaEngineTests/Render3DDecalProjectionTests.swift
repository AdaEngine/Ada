#if os(macOS) || os(Windows) || os(Linux)
import AdaAnimation
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
@testable import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("3D decal projection")
    @MainActor
    struct DecalProjection {
        private struct PatchFace {
            let corners: [Int]
            let footprint: [DecalTriangle3D.Vertex]
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func startupPlacementUsesTheNewReceiverTransform() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let mesh = Mesh.generateCube(renderDevice: scene.device)
            let car = scene.app.main.spawn("Car setup") {
                Mesh3DComponent(mesh: mesh, materials: [PBRMaterial()])
                Transform(position: [8, 0, 0])
            }
            let projector = Decal3D.Projector(
                transform: Transform(rotation: Quat.euler([0, .pi, 0]), position: [8, 0, -0.5]).matrix,
                size: [0.2, 0.2, 0.2]
            )
            let artwork = Image(width: 1, height: 1, color: Color(1, 0, 0, 1))
            let handle = try? Decal3D.place(on: car, projector: projector, appearance: .init(color: artwork))
            #expect(handle != nil, "A stamp on a newly spawned car uses the car's initial transform")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func rigidDecalsTrackOnlyTheirReceiverAndBlendSurfaceChannels() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
            let mesh = Mesh.generateCube(renderDevice: scene.device)
            let material = PBRMaterial()
            material.baseColorFactor = [0.5, 0.5, 0.5, 1]
            material.roughnessFactor = 0.8
            let left = scene.app.main.spawn("Target car") {
                Mesh3DComponent(mesh: mesh, materials: [material])
                Transform(position: [-0.65, 0.65, 0])
            }
            let right = scene.app.main.spawn("Other car") {
                Mesh3DComponent(mesh: mesh, materials: [material])
                Transform(position: [0.65, 0.65, 0])
            }
            let leftPoint = Vector3(-0.65, 0.65, -0.5)
            let rightPoint = Vector3(0.65, 0.65, -0.5)
            let start = try await scene.render(.albedo)
            let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
            let sharedColor = try Self.sample(at: rightPoint, image: start, camera: camera)
            let baseDepth = try await scene.render(.depth)
            let baseNormals = try await scene.render(.normals)

            let projector = Decal3D.Projector(
                transform: Transform(rotation: Quat.euler([0, .pi, 0]), position: leftPoint).matrix,
                size: [0.45, 0.45, 0.2]
            )
            let red = Image(width: 1, height: 1, color: Color(1, 0, 0, 1))
            let panel = try Decal3D.place(on: left, projector: projector, appearance: .init(
                color: red,
                normal: Image(width: 1, height: 1, color: Color(0.85, 0.5, 0.85, 1)),
                roughness: Image(width: 1, height: 1, color: Color(0.25, 0.25, 0.25, 1))
            ))
            let marked = try await scene.render(.albedo)
            let first = try Self.sample(at: leftPoint, image: marked, camera: camera)
            let other = try Self.sample(at: rightPoint, image: marked, camera: camera)
            #expect(first.red > 0.8 && first.green < 0.15)
            #expect(other == sharedColor)
            let normals = try await scene.render(.normals)
            let oldNormal = try Self.sample(at: leftPoint, image: baseNormals, camera: camera)
            let newNormal = try Self.sample(at: leftPoint, image: normals, camera: camera)
            #expect(oldNormal != newNormal)
            let roughnessFrame = try await scene.render(.roughness)
            let roughness = try Self.sample(at: leftPoint, image: roughnessFrame, camera: camera)
            #expect(abs(roughness.red - 0.25) < 0.06)
            let decalDepth = try await scene.render(.depth)
            #expect(decalDepth.data == baseDepth.data)

            let overlay = try Decal3D.place(on: left, projector: projector, appearance: .init(
                color: Image(width: 1, height: 1, color: Color(0, 1, 0, 0.5))
            ))
            let overlapped = try await scene.render(.albedo)
            let mix = try Self.sample(at: leftPoint, image: overlapped, camera: camera)
            #expect(mix.red > 0.45 && mix.green > 0.45 && mix.blue < 0.15)
            try Decal3D.remove(overlay, from: left)
            let moved = leftPoint + Vector3(0, 0.45, 0)
            left.components[Transform.self] = Transform(position: [-0.65, 1.1, 0])
            try Decal3D.update(panel, on: left, appearance: .init(color: Image(width: 1, height: 1, color: Color(0, 0, 1, 1))))
            let translated = try await scene.render(.albedo)
            let movedColor = try Self.sample(at: moved, image: translated, camera: camera)
            #expect(movedColor.blue > 0.8 && movedColor.red < 0.15)
            #expect(throws: Decal3D.PlacementError.staleHandle) {
                try Decal3D.remove(panel, from: right)
            }
            try Decal3D.remove(panel, from: left)
            let removed = try await scene.render(.albedo)
            let restored = try Self.sample(at: moved, image: removed, camera: camera)
            #expect(restored == sharedColor)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func projectedPatchTracksTheBentRibbonAcrossPoses() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
            GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/SkeletalGardenAssets/TwoBoneRibbon.glb")
            let asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: fixture.path).asset)
            let root = asset.instantiate(in: scene.app.main)
            let ribbon = try #require(root.children.first { $0.components[SkinnedMesh3DComponent.self] != nil })
            let source = try #require(ribbon.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first?.meshDescriptor)
            let original = try #require(ribbon.components[Mesh3DComponent.self]?.mesh)
            let paper = PBRMaterial()
            paper.doubleSided = true
            paper.baseColorFactor = [0.4, 0.4, 0.4, 1]
            ribbon.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: original, materials: [paper])

            let bent = try await Self.samplePose(0.5, root: root, ribbon: ribbon, source: source, scene: scene)
            let projectorScale = Vector3(0.21, 0.68, 0.4)
            let projectorCenter = Vector3(-0.18, 1, 0)
            func project(_ corner: Int) -> Vector3 {
                let offset = bent[corner] - projectorCenter
                return Vector3(offset.x / projectorScale.x, offset.y / projectorScale.y, offset.z / projectorScale.z)
            }
            let faces = stride(from: 0, to: source.indicies.count, by: 3).compactMap { index -> PatchFace? in
                let corners = source.indicies[index..<index + 3].map(Int.init)
                let footprint = DecalTriangle3D.clip(project(corners[0]), project(corners[1]), project(corners[2]))
                return footprint.isEmpty ? nil : PatchFace(corners: corners, footprint: footprint)
            }
            try #require(faces.count >= 2)

            // Draw the clipped patch with the standard renderer to isolate the geometry proof from PBR composition.
            let material = PBRMaterial()
            material.doubleSided = true
            let patch = scene.app.main.spawn("Projected patch") { Transform(position: [0, 0, -0.002]) }
            func frame(with pose: [Vector3]) async throws -> Image {
                let mesh = Self.patchMesh(faces, pose: pose, device: scene.device)
                patch.components[Mesh3DComponent.self] = Mesh3DComponent(
                    mesh: mesh, materials: [material], castShadows: false, receiveShadows: false
                )
                return try await scene.render(.albedo)
            }
            let bentFrame = try await frame(with: bent)
            let straight = try await Self.samplePose(0, root: root, ribbon: ribbon, source: source, scene: scene)
            let straightFrame = try await frame(with: straight)
            let bentAgain = try await Self.samplePose(0.5, root: root, ribbon: ribbon, source: source, scene: scene)
            let repeatedFrame = try await frame(with: bentAgain)

            let first = Self.patchPixels(bentFrame)
            let second = Self.patchPixels(straightFrame)
            #expect(first.count > 100 && second.count > 100)
            #expect(first.symmetricDifference(second).count > 100)
            #expect(first == Self.patchPixels(repeatedFrame))

            let receiver = try #require(ribbon.components[GlobalTransform.self]?.matrix)
            let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
            for (image, pose) in [(bentFrame, bent), (straightFrame, straight), (repeatedFrame, bentAgain)] {
                let upper = try Self.sampleAnchor([4, 6, 7], image: image, pose: pose, receiver: receiver, camera: camera)
                let lower = try Self.sampleAnchor([2, 4, 5], image: image, pose: pose, receiver: receiver, camera: camera)
                #expect(upper.red < 0.2 && upper.green > 0.8 && upper.blue > 0.8, "Cyan upper anchor must track the original triangle")
                #expect(lower.red > 0.8 && lower.green < 0.2 && lower.blue > 0.8, "Magenta lower anchor must track the original triangle")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func surfaceDecalUsesTheBentPlacementPoseAndStaysThroughAnimation() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for sphere in scene.sphereEntities { sphere.components[Visibility.self] = .hidden }
            GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/SkeletalGardenAssets/TwoBoneRibbon.glb")
            let asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: fixture.path).asset)
            let root = asset.instantiate(in: scene.app.main)
            let ribbon = try #require(root.children.first { $0.components[SkinnedMesh3DComponent.self] != nil })
            let original = try #require(ribbon.components[Mesh3DComponent.self]?.mesh)
            let source = try #require(original.models.first?.parts.first?.meshDescriptor)
            let material = PBRMaterial()
            material.doubleSided = true
            material.baseColorFactor = [0.4, 0.4, 0.4, 1]
            ribbon.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: original, materials: [material])

            let pose = try await Self.samplePose(0.5, root: root, ribbon: ribbon, source: source, scene: scene)
            let base = try await scene.render(.albedo)
            let receiver = try #require(ribbon.components[GlobalTransform.self]?.matrix)
            let camera = try #require(scene.camera.components[GlobalViewUniform.self]?.viewProjectionMatrix)
            var artwork = Image(width: 1, height: 8, color: Color(1, 0, 1, 1))
            for row in 0..<4 { artwork.setPixel(in: [0, Float(row)], color: Color(0, 1, 1, 1)) }
            let projector = Decal3D.Projector(transform: Transform3D(translation: [-0.18, 1, 0]), size: [0.42, 1.36, 0.8])
            let handle = try Decal3D.place(on: ribbon, projector: projector, appearance: .init(color: artwork))
            let bent = try await scene.render(.albedo)
            let straightPose = try await Self.samplePose(0, root: root, ribbon: ribbon, source: source, scene: scene)
            let straight = try await scene.render(.albedo)
            for (image, currentPose) in [(bent, pose), (straight, straightPose)] {
                let upper = try Self.sampleAnchor([4, 6, 7], image: image, pose: currentPose, receiver: receiver, camera: camera)
                let lower = try Self.sampleAnchor([2, 4, 5], image: image, pose: currentPose, receiver: receiver, camera: camera)
                #expect(upper.red < 0.2 && upper.green > 0.8 && upper.blue > 0.8)
                #expect(lower.red > 0.8 && lower.green < 0.2 && lower.blue > 0.8)
            }
            _ = try await Self.samplePose(0.5, root: root, ribbon: ribbon, source: source, scene: scene)
            let rebent = try await scene.render(.albedo)
            #expect(Self.patchPixels(rebent) == Self.patchPixels(bent))
            try Decal3D.remove(handle, from: ribbon)
            let restored = try await scene.render(.albedo)
            #expect(restored.data == base.data)
        }

        private static func samplePose(
            _ time: Double,
            root: Entity,
            ribbon: Entity,
            source: MeshDescriptor,
            scene: Render3DDebugViewGPUTests.Scene
        ) async throws -> [Vector3] {
            var animation = try #require(root.components[ModelAnimation3DComponent.self])
            try animation.player.play("Bend", transitionDuration: 0)
            animation.player.seek(to: time)
            animation.player.isPlaying = false
            root.components[ModelAnimation3DComponent.self] = animation
            await scene.app.main.runScheduler(.postUpdate, deltaTime: 0)
            let palette = try #require(ribbon.components[SkinnedMesh3DComponent.self]?.matrices)
            let joints = try #require(source[MeshDescriptor.jointIndices]).elements
            let weights = try #require(source[MeshDescriptor.jointWeights]).elements
            return source.positions.elements.enumerated().map { index, point in
                var posed = Vector3.zero
                for influence in 0..<4 where weights[index][influence] > 0 {
                    let joint = palette[Int(joints[index][influence])]
                    posed += (joint * Vector4(point, 1)).xyz * weights[index][influence]
                }
                return posed
            }
        }

        private static func patchMesh(_ faces: [PatchFace], pose: [Vector3], device: RenderDevice) -> Mesh {
            var colors: [Color] = []
            var positions: [Vector3] = []
            var indices: [UInt32] = []
            for face in faces {
                let offset = UInt32(positions.count)
                positions += face.footprint.map {
                    $0.position(on: pose[face.corners[0]], pose[face.corners[1]], pose[face.corners[2]])
                }
                let color = Set(face.corners) == [4, 6, 7] ? Color(0, 1, 1, 1) : Color(1, 0, 1, 1)
                colors += Array(repeating: color, count: face.footprint.count)
                for index in 1..<face.footprint.count - 1 {
                    indices += [offset, offset + UInt32(index), offset + UInt32(index + 1)]
                }
            }
            var mesh = MeshDescriptor(name: "Projected 3D decal")
            mesh.colors = MeshBuffer(colors)
            mesh.positions = MeshBuffer(positions)
            mesh.normals = MeshBuffer(positions.map { _ in Vector3(0, 0, 1) })
            mesh.indicies = indices
            return Mesh.generate(from: [mesh], renderDevice: device)
        }

        private static func sampleAnchor(
            _ indices: [Int],
            image: Image,
            pose: [Vector3],
            receiver: Transform3D,
            camera: Transform3D
        ) throws -> Color {
            let local = (pose[indices[0]] + pose[indices[1]] + pose[indices[2]]) * (1 / 3)
            return try sample(at: (receiver * Vector4(local, 1)).xyz, image: image, camera: camera)
        }

        private static func sample(at point: Vector3, image: Image, camera: Transform3D) throws -> Color {
            let clip = camera * Vector4(point, 1)
            let x = Int((0.5 + 0.5 * clip.x / clip.w) * Float(image.width))
            let y = Int((0.5 - 0.5 * clip.y / clip.w) * Float(image.height))
            try #require((0..<image.width).contains(x) && (0..<image.height).contains(y))
            return image.getPixel(x: x, y: y)
        }

        private static func patchPixels(_ image: Image) -> Set<Int> {
            var pixels: Set<Int> = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let pixel = image.getPixel(x: x, y: y)
                    if pixel.blue > 0.8 && (pixel.red > 0.8 && pixel.green < 0.2 || pixel.red < 0.2 && pixel.green > 0.8) {
                        pixels.insert(y * image.width + x)
                    }
                }
            }
            return pixels
        }
    }
}
#endif
