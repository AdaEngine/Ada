import AdaEngine
@_spi(Internal) @testable import AdaRender
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
    func fullCharacterHasThreeClipsAndIndependentSkinInstances() throws {
        try setup()
        let model = try loadModel("GardenRobot")
        #expect(Set(model.animationClips.map(\.name)) == ["Idle", "Walk", "Run"])
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
