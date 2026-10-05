import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@MainActor
@Suite
struct PBR3DSceneTests {
    @Test
    func realGLBRetainsORMNormalEmissionMaskAndSamplerSettings() throws {
        try setup()
        let crate = try loadModel("Crate")
        let wood = try #require(crate.materials.compactMap { $0 as? PBRMaterial }.first { $0.normalTexture != nil })
        #expect(wood.baseColorTexture != nil)
        #expect(wood.occlusionTexture != nil)
        #expect(wood.normalScale == 0.6)
        #expect(wood.baseColorTexture?.sampler.descriptor.addressModeU == .repeat)
        #expect(wood.baseColorTexture?.sampler.descriptor.mipFilter == .linear)
        let plant = try loadModel("Plant")
        let leaf = try #require(plant.materials.compactMap { $0 as? PBRMaterial }.first { $0.alphaMode == .mask })
        #expect(leaf.doubleSided)
        #expect(leaf.alphaCutoff == 0.5)
        #expect(leaf.baseColorTexture != nil)
        let lamp = try loadModel("Lantern")
        let emission = try #require(lamp.materials.compactMap { $0 as? PBRMaterial }.first { $0.emissiveFactor.x > 0 })
        #expect(emission.emissiveTexture == nil)
        #expect(emission.emissiveStrength > 1)
    }

    @Test
    func fullCharacterHasLocomotionAndAirClipsWithIndependentSkinInstances() throws {
        try setup()
        let model = try loadModel("GardenRobot")
        #expect(Set(model.animationClips.map(\.name)) == ["Idle", "Walk", "Run", "Jump", "Fall", "Land"])
        #expect(model.skins.allSatisfy { $0.joints.count == 43 })
        #expect(model.meshes.count > 5)
        let world = World()
        let first = model.instantiate(in: world)
        let second = model.instantiate(in: world)
        var player = try #require(first.components[ModelAnimation3DComponent.self])
        try player.player.play("Walk", transitionDuration: 0)
        player.player.seek(to: 0.3)
        first.components[ModelAnimation3DComponent.self] = player
        #expect(second.components[ModelAnimation3DComponent.self]?.player.clipIndex == nil)
    }

    @Test
    func hdrIBLLoadsLinearMapsAndSixRoughnessLevels() throws {
        try setup()
        let url = assets().appendingPathComponent("Studio.ibl")
        let ibl = try #require(AssetsManager.loadSync(ImageBasedLighting3D.self, at: url.path).asset)
        #expect(ibl.specularLevels == 6)
        #expect(ibl.irradiance.size == SizeInt(width: 32, height: 16))
        #expect(ibl.specular.size == SizeInt(width: 128, height: 384))
        #expect(ibl.brdf.size == SizeInt(width: 64, height: 64))
        #expect(ibl.radiance != nil)
        #expect(ibl.irradiance.sampler.descriptor.addressModeU == .repeat)
        #expect(ibl.brdf.sampler.descriptor.addressModeU == .clampToEdge)
    }

    @Test(arguments: [
        (UInt16(0x0000), true), (0x8000, true), // Both signs of zero.
        (0x0001, true), (0x03FF, true), (0x0400, true), (0x3C00, true), (0x7BFF, true),
        (0x8001, false), (0x83FF, false), (0x8400, false), (0xBC00, false), (0xFBFF, false),
        (0x7C00, false), (0xFC00, false), // Infinities.
        (0x7C01, false), (0x7E00, false), (0xFC01, false), (0xFE00, false), // NaNs.
    ])
    func hdrIBLValidatesBinary16Radiance(bits: UInt16, isValid: Bool) throws {
        try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8), 0, 0, 0, 0, 0, 0])
        try data.write(to: directory.appendingPathComponent("map.rgba16f"))
        try (data + data).write(to: directory.appendingPathComponent("specular.rgba16f"))
        let manifest = """
        {"version":1,"specularLevels":2,
         "radiance":{"file":"map.rgba16f","width":1,"height":1},
         "irradiance":{"file":"map.rgba16f","width":1,"height":1},
         "specular":{"file":"specular.rgba16f","width":1,"height":2},
         "brdf":{"file":"map.rgba16f","width":1,"height":1}}
        """
        let url = directory.appendingPathComponent("Test.ibl")
        try Data(manifest.utf8).write(to: url)
        if isValid {
            let ibl = try #require(AssetsManager.loadSync(ImageBasedLighting3D.self, at: url.path).asset)
            #expect(ibl.radiance != nil)
        } else {
            #expect(throws: AssetError.self) {
                try AssetsManager.loadSync(ImageBasedLighting3D.self, at: url.path)
            }
        }
    }

    @Test
    func blendPipelineTestsDepthWithoutWritingItAndOpaqueWritesDepth() throws {
        try setup()
        var mesh = MeshDescriptor(name: "Material Test")
        mesh.positions = MeshBuffer([Vector3.zero])
        let pipeline = PBR3DPipeline()
        let transparent = pipeline.configurate(with: PBR3DConfiguration(vertex: mesh.getMeshVertexBufferDescriptor(), blended: true))
        let opaque = pipeline.configurate(with: PBR3DConfiguration(vertex: mesh.getMeshVertexBufferDescriptor(), blended: false))
        #expect(transparent.depthStencilDescriptor?.isDepthTestEnabled == true)
        #expect(transparent.depthStencilDescriptor?.isDepthWriteEnabled == false)
        #expect(opaque.depthStencilDescriptor?.isDepthWriteEnabled == true)
    }

    private func setup() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
    }

    private func assets() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Demos/SkeletalGarden/Assets")
    }

    private func loadModel(_ name: String) throws -> ModelAsset3D {
        try #require(AssetsManager.loadSync(ModelAsset3D.self, at: assets().appendingPathComponent(name + ".glb").path).asset)
    }
}
