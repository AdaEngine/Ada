#if os(macOS) || os(Windows) || os(Linux)
#if os(Windows) || (os(macOS) && SAGA_METAL_NATIVE_PASS)
import AdaAnimation
import Foundation
#endif
#if os(macOS) && SAGA_METAL_NATIVE_PASS
import Metal
#endif
@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("Shadow cache lifetime through deferred camera extraction", .enabled(if: GoldenFrame.isEnabled))
    struct ShadowCacheLifetime {
        private static func fixture() async throws -> MeshletBaselineFixtures.Scene {
            let scene = try await MeshletBaselineFixtures.empty(size: [96, 64], shadows: true)
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.localShadows = .init(maximumLights: 4, resolution: 128)
            environment.shadows.resolution = 128
            environment.gpuOcclusionEnabled = false
            environment.meshVisibility.meshlets = .gpu
            scene.camera.components[Environment3D.self] = environment
            let materials = (0..<16).map { _ in PBRMaterial() }
            materials[0].alphaMode = .mask
            let mesh = Mesh.generateCube(renderDevice: scene.device)
            for index in 0..<4 {
                scene.app.main.spawn("Static shared-table caster \(index)") {
                    Mesh3DComponent(mesh: mesh, materials: materials)
                    Transform(position: [Float(index) - 1.5, 0, 3])
                }
                scene.app.main.spawn("Static cached spotlight \(index)") {
                    SpotLightComponent(intensity: 5, castShadows: true, range: 10)
                    Transform(position: [Float(index) - 1.5, 0, 0])
                }
            }
            return scene
        }

        private static func completeFrame(_ scene: MeshletBaselineFixtures.Scene, frames: Int = 1) async throws {
            for _ in 0..<frames { try await scene.app.update() }
            _ = try #require(try await scene.device.readImage(from: scene.target))
        }

            @Test
            func replacingIndicesInvalidatesShadowCasterDigest() async throws {
                let scene = try await Self.fixture()
                try await Self.completeFrame(scene)
                let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                var caster = try #require(world.getResource(ExtractedMesh3DSources.self)?.meshes.first)
                let before = try #require(ShadowSceneDigest3D.compute(sources: [caster], usesLOD: false))
                var models = caster.mesh.models
                let original = models[0].parts[0].indexBuffer
                let bytes = Array(repeating: UInt8(0), count: original.length)
                models[0].parts[0].indexBuffer = try bytes.withUnsafeBytes { buffer in
                    let address = try #require(buffer.baseAddress)
                    return scene.device.createIndexBuffer(format: original.indexFormat, bytes: address, length: buffer.count)
                }
                caster.mesh = Mesh(models: models)
                let after = try #require(ShadowSceneDigest3D.compute(sources: [caster], usesLOD: false))
                #expect(before != after, "Replacing index storage must invalidate the rendered shadow.")
            }

            #if os(Windows) || (os(macOS) && SAGA_METAL_NATIVE_PASS)
                @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
                func staticShadowDigestSurvivesRebuiltDrawBindings() async throws {
                    let scene = try await Self.fixture()
                    try await Self.completeFrame(scene)
                    let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                    let sources = try #require(world.getResource(ExtractedMesh3DSources.self))
                    var caster = try #require(sources.meshes.first)
                    let material = PBRMaterial()
                    caster.materials = caster.materials.map { _ in material }
                    caster.previousTransform = caster.transform
                    var other = caster
                    other.transform = Transform3D(translation: [2, 0, 3])
                    other.previousTransform = other.transform

                    var lists = VisibleMesh3DLists()
                    var firstBindings = PBR3DUniforms()
                    var rebuiltBindings = PBR3DUniforms()
                    func digest(_ casters: [Mesh3DRenderSource], materials: inout PBR3DUniforms) -> UInt64 {
                        lists.prepareShadowCacheLayers(
                            ShadowCasterLayers3D(casters),
                            view: scene.camera.id,
                            pass: 300,
                            uniform: GlobalViewUniform(),
                            lightProjection: .identity,
                            settings: .init(frustumCulling: false, lod: false, distanceCulling: false),
                            device: scene.device,
                            materials: &materials,
                            preparedDigest: nil
                        ).digest
                    }
                    let original = digest([caster, other], materials: &firstBindings)
                    let rebuilt = digest([caster, other], materials: &rebuiltBindings)
                    let firstBuffer = try #require(firstBindings.buffer(for: material))
                    let rebuiltBuffer = try #require(rebuiltBindings.buffer(for: material))
                    try #require(ObjectIdentifier(firstBuffer) != ObjectIdentifier(rebuiltBuffer))
                    #expect(original == rebuilt, "Rebuilding GPU material bindings must preserve the static shadow digest.")
                    #expect(original == digest([other, caster], materials: &rebuiltBindings))
                    #expect(original != digest([caster], materials: &rebuiltBindings))
                    other.transform = Transform3D(translation: [3, 0, 3])
                    other.previousTransform = other.transform
                    #expect(original != digest([caster, other], materials: &rebuiltBindings))
                    other.transform = Transform3D(translation: [2, 0, 3])
                    other.previousTransform = other.transform
                    material.doubleSided = true
                    #expect(original != digest([caster, other], materials: &rebuiltBindings))
                }

                @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
                func shadowBatchesDistinguishSharedGeometry() async throws {
                    let scene = try await Self.fixture()
                    try await Self.completeFrame(scene)
                    let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                    let sources = try #require(world.getResource(ExtractedMesh3DSources.self))
                    var whole = try #require(sources.meshes.first)
                    whole.materials = whole.materials.map { _ in PBRMaterial() }
                    var partial = whole
                    var models = whole.mesh.models
                    models[0].parts[0].indexCount = 3
                    partial.mesh = Mesh(models: models)

                    var lists = VisibleMesh3DLists()
                    var materials = PBR3DUniforms()
                    lists.prepare(
                        sources: [whole, partial, whole],
                        view: scene.camera.id,
                        pass: 0,
                        viewMatrix: .identity,
                        projection: .identity,
                        cullingProjection: .identity,
                        settings: .init(frustumCulling: false, lod: false, distanceCulling: false),
                        device: scene.device,
                        materials: &materials
                    )
                    let items = lists.items(view: scene.camera.id, pass: 0)
                    try #require(items.count == 2)
                    let buffers = lists.buffers(view: scene.camera.id, pass: 0)
                    let instances = try #require(buffers.instances)
                    let atlas = RenderTexture(size: [32, 32], scaleFactor: 1, format: .rgba_32f)
                    let depth = RenderTexture(size: [32, 32], scaleFactor: 1, format: .depth_32f_stencil8, usage: [.renderTarget])
                    let command = scene.device.createCommandQueue().makeCommandBuffer()
                    let pass = command.beginRenderPass(.init(
                        colorAttachments: [.init(texture: atlas, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white)],
                        depthStencilAttachment: .init(
                            texture: depth,
                            depthOperation: .init(loadAction: .clear, storeAction: .dontCare),
                            stencilOperation: .init(loadAction: .clear, storeAction: .dontCare)
                        )
                    ))
                    let constants = scene.device.createUniformBuffer(DirectionalShadowViewUniform.self, binding: GlobalBufferIndex.viewUniform)
                    constants.setData(DirectionalShadowViewUniform(viewProjection: .identity))
                    pass.setVertexBuffer(constants, offset: 0, slot: GlobalBufferIndex.viewUniform)
                    var palettes = Skinning3DUniforms()
                    palettes.beginFrame(device: scene.device)
                    var batches = ShadowBatchEncoder3D(requiresMaterialBuffer: true)
                    var pipelines = RenderPipelines(configurator: DirectionalShadow3DPipeline())
                    let encoded = batches.encode(
                        items: items,
                        instances: instances,
                        defaults: buffers.defaults,
                        pass: pass,
                        pipelines: &pipelines,
                        materials: materials,
                        identityPalette: palettes.identityBuffer,
                        device: scene.device
                    )
                    pass.endRenderPass()
                    #expect(encoded == 2)
                    #expect(batches.resolvedStateCount == 2, "Distinct index counts must preserve separate shadow draw states.")
                }

                @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
                func staticShadowListTracksOnlyRelevantCameraChanges() async throws {
                    let scene = try await Self.fixture()
                    try await Self.completeFrame(scene)
                    let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                    let sources = try #require(world.getResource(ExtractedMesh3DSources.self))
                    var caster = try #require(sources.meshes.first)
                    caster.materials = caster.materials.map { _ in PBRMaterial() }
                    caster.previousTransform = caster.transform
                    try #require(!ShadowCasterLayers3D([caster]).staticCasters.isEmpty)
                    let moved = GlobalViewUniform(viewMatrix: Transform3D(translation: [1, 0, 0]))
                    func changesWithCamera(_ source: Mesh3DRenderSource, _ settings: MeshVisibilitySettings3D) -> Bool {
                        let layers = ShadowCasterLayers3D([source])
                        return layers.preparationKey(uniform: moved, lightProjection: .identity, settings: settings)
                            != layers.preparationKey(uniform: GlobalViewUniform(), lightProjection: .identity, settings: settings)
                    }
                    caster.maximumDistance = nil
                    caster.alternatives = []
                    #expect(!changesWithCamera(caster, .init()))
                    caster.maximumDistance = 20
                    #expect(changesWithCamera(caster, .init()))
                    #expect(!changesWithCamera(caster, .init(distanceCulling: false)))
                    caster.maximumDistance = nil
                    caster.alternatives = [caster.mesh]
                    #expect(changesWithCamera(caster, .init()))
                    #expect(!changesWithCamera(caster, .init(lod: false)))
                }

                private struct AnimatedFixture {
                    let scene: MeshletBaselineFixtures.Scene
                    let world: World
                    let caster: Entity
                    let staticCaster: Entity
                    let light: Entity
                }

                private static func animatedFixture(cache: Bool) async throws -> AnimatedFixture {
                    let scene = try await MeshletBaselineFixtures.empty(size: [144, 96], shadows: true)
                    let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                    if cache { world.insertResource(StudioShadowCache()) }
                    var environment = try #require(scene.camera.components[Environment3D.self])
                    environment.localShadows = .init(maximumLights: 1, resolution: 128)
                    environment.shadowCascadeCount = 2
                    environment.shadows.resolution = 256
                    environment.meshVisibility.lod = false
                    scene.camera.components[Environment3D.self] = environment
                    let material = PBRMaterial()
                    let cube = Mesh.generateCube(size: [0.8, 0.8, 0.8], renderDevice: scene.device)
                    let staticCaster = scene.app.main.spawn("Static caster") {
                        Mesh3DComponent(mesh: cube, materials: [material])
                        Transform(position: [-1.25, 0, 4])
                    }
                    scene.app.main.spawn("Shadow receiver") {
                        Mesh3DComponent(mesh: .generateCube(size: [8, 0.2, 8], renderDevice: scene.device), materials: [material])
                        Transform(position: [0, -0.7, 4])
                    }
                    let light = scene.app.main.spawn("Shadow spotlight") {
                        SpotLightComponent(intensity: 20, castShadows: true, range: 14)
                        Transform(position: [0, 0, 0])
                    }
                    var descriptor = try #require(cube.models.first?.parts.first).meshDescriptor
                    let count = descriptor.positions.elements.count
                    descriptor[MeshDescriptor.jointIndices] = MeshBuffer(Array(repeating: Vector4.zero, count: count))
                    descriptor[MeshDescriptor.jointWeights] = MeshBuffer(Array(repeating: Vector4(1, 0, 0, 0), count: count))
                    let mesh = Mesh.generate(from: [descriptor], renderDevice: scene.device)
                    let caster = scene.app.main.spawn("Skinned caster") {
                        Mesh3DComponent(mesh: mesh, materials: [material])
                        Transform(position: [0, 0, 3])
                    }
                    return .init(scene: scene, world: world, caster: caster, staticCaster: staticCaster, light: light)
                }

                private static func setJoint(_ position: Vector3, on caster: Entity) throws {
                    let rig = try SkeletalRig(nodes: [
                        .init(parentIndex: nil, restPose: .init(), restMatrix: .identity),
                        .init(parentIndex: nil, restPose: .init(translation: position), restMatrix: Transform3D(translation: position)),
                    ])
                    var binding = SkinnedMesh3DComponent(
                        modelRoot: caster.id,
                        meshNodeIndex: 0,
                        skin: .init(name: nil, joints: [1], skeletonRootIndex: 1, inverseBindMatrices: [.identity])
                    )
                    binding.updateMatrices(using: try SkeletalAnimationPlayer(rig: rig, clips: []))
                    caster.components[SkinnedMesh3DComponent.self] = binding
                }

                private static func shadowDepth(_ texture: RenderTexture, on device: RenderDevice) async throws -> [Float] {
                    let size = texture.size
                    let bytesPerPixel = texture.pixelFormat == .r32f ? 4 : 16
                    let rowBytes = (size.width * bytesPerPixel + 255) & ~255
                    let byteCount = rowBytes * size.height
                    let staging = device.createBuffer(label: "Shadow cache depth comparison", length: byteCount, options: .storageShared)
                    #if os(Windows)
                    let command = device.createCommandQueue().makeCommandBuffer()
                    let blit = command.beginBlitPass(BlitPassDescriptor())
                    blit.copyTextureToBuffer(
                        source: texture,
                        sourceOrigin: Origin3D(),
                        sourceMipLevel: 0,
                        sourceSlice: 0,
                        sourceSize: Size3D(width: size.width, height: size.height),
                        destination: staging,
                        destinationOffset: 0,
                        destinationBytesPerRow: rowBytes,
                        destinationBytesPerImage: byteCount
                    )
                    blit.endBlitPass()
                    command.commit()
                    #else
                    try await MetalInterop.submitSAGAMetalPass(
                        on: device,
                        label: "Read shadow cache test",
                        textures: [.init(texture)],
                        buffers: [.init(staging, access: .write)]
                    ) { commands, textures, buffers in
                        let source = try #require(textures.first)
                        let destination = try #require(buffers.first)
                        let blit = try #require(commands.makeBlitCommandEncoder())
                        blit.copy(
                            from: source,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(),
                            sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                            to: destination,
                            destinationOffset: 0,
                            destinationBytesPerRow: rowBytes,
                            destinationBytesPerImage: byteCount
                        )
                        blit.endEncoding()
                    }
                    #endif
                    let data = try await staging.readData()
                    return unsafe data.withUnsafeBytes { bytes in
                        (0..<size.height).flatMap { y in
                            (0..<size.width).map { x in
                                bytes.loadUnaligned(fromByteOffset: y * rowBytes + x * bytesPerPixel, as: Float.self)
                            }
                        }
                    }
                }

                private static func shadowMaps(_ fixture: AnimatedFixture) async throws -> (sun: [Float], spot: [Float], image: Image) {
                    try await fixture.scene.app.update()
                    let image = try #require(try await fixture.scene.device.readImage(from: fixture.scene.target))
                    let sun = try #require(fixture.world.getResource(DirectionalShadow3D.self)?.colorTexture)
                    let spot = try #require(fixture.world.getResource(LocalShadow3DViews.self)?.entries[fixture.scene.camera.id]?.color)
                    return (try await shadowDepth(sun, on: fixture.scene.device), try await shadowDepth(spot, on: fixture.scene.device), image)
                }

                private static func removeStaticTriangles(_ fixture: AnimatedFixture) async throws {
                    let mesh = try #require(fixture.staticCaster.components[Mesh3DComponent.self]?.mesh)
                    let buffer = try #require(mesh.models.first?.parts.first?.indexBuffer)
                    #if os(Windows)
                    let bytes = [UInt8](repeating: 0, count: buffer.length)
                    let source = try bytes.withUnsafeBytes { raw in
                        let address = try #require(raw.baseAddress)
                        return fixture.scene.device.createBuffer(label: "Zero indices", bytes: address, length: raw.count, options: .storageShared)
                    }
                    let command = fixture.scene.device.createCommandQueue().makeCommandBuffer()
                    let blit = command.beginBlitPass(BlitPassDescriptor())
                    blit.copyBufferToBuffer(source: source, sourceOffset: 0, destination: buffer, destinationOffset: 0, size: buffer.length)
                    blit.endBlitPass()
                    command.commit()
                    #else
                    try await MetalInterop.submitSAGAMetalPass(
                        on: fixture.scene.device,
                        label: "Change static shadow topology",
                        buffers: [.init(buffer, access: .write)]
                    ) { commands, _, buffers in
                        let destination = try #require(buffers.first)
                        let blit = try #require(commands.makeBlitCommandEncoder())
                        blit.fill(buffer: destination, range: 0..<buffer.length, value: 0)
                        blit.endEncoding()
                    }
                    #endif
                }

                @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
                func editShadowCacheMatchesFullDrawOnTheFirstChangedFrame() async throws {
                    let cached = try await Self.animatedFixture(cache: true)
                    let reference = try await Self.animatedFixture(cache: false)
                    for fixture in [cached, reference] {
                        try Self.setJoint(.zero, on: fixture.caster)
                        try await Self.completeFrame(fixture.scene, frames: 4)
                    }
                    var previousSun: [Float] = []
                    var previousSpot: [Float] = []
                    var previousStaticWrites = 0
                    var previousProjection = Transform3D.identity
                    for step in 0...6 {
                        for fixture in [cached, reference] {
                            let joint: Vector3 = step < 2 ? [Float(step) * 0.55, 0, 0] : [2.5, 0, 0]
                            if step < 3 { try Self.setJoint(joint, on: fixture.caster) }
                            if step == 2 {
                                let transform = Transform(
                                    rotation: Quat(axis: .up, angle: 0.24),
                                    position: [-2, 1, -11]
                                )
                                fixture.scene.camera.components[Transform.self] = transform
                                // CameraSystem consumes the global pose before the normal post-update transform propagation.
                                fixture.scene.camera.components[GlobalTransform.self] = GlobalTransform(matrix: transform.matrix)
                            }
                            if step == 3 { fixture.scene.app.main.removeEntity(fixture.caster) }
                            if step == 4 {
                                fixture.light.components[Transform.self] = Transform(position: [0.25, 0, 0])
                            }
                            if step == 5 { try await Self.removeStaticTriangles(fixture) }
                            if step == 6 {
                                var environment = try #require(fixture.scene.camera.components[Environment3D.self])
                                environment.shadows.resolution = 512
                                environment.localShadows.resolution = 256
                                fixture.scene.camera.components[Environment3D.self] = environment
                            }
                        }
                        let actual = try await Self.shadowMaps(cached)
                        let expected = try await Self.shadowMaps(reference)
                        let compare: ([Float], [Float]) -> Bool = { a, b in
                            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.00001 }
                        }
                        #expect(compare(actual.sun, expected.sun), "Directional shadow is out of date on frame \(step).")
                        #expect(compare(actual.spot, expected.spot), "Spot shadow is out of date on frame \(step).")
                        #expect(
                            GoldenFrame.compare(actual.image, expected.image, tolerance: GoldenFrame.activeTolerance).passes(
                                GoldenFrame.activeTolerance
                            ),
                            "The composed frame differs from the full draw on frame \(step)."
                        )
                        let scratch = try #require(cached.world.getResource(DirectionalShadow3DScratch.self))
                        let projection = try #require(cached.world.getResource(DirectionalShadow3D.self)).viewProjection
                        let writes = scratch.shadowMapCache.totalStaticTilesDrawn
                        if step == 0 { #expect(writes > 0) }
                        if step == 1 {
                            #expect(writes == previousStaticWrites, "Joint movement must reuse the static shadow atlas.")
                            #expect(!compare(previousSun, actual.sun), "The joint must actually move the directional shadow.")
                            #expect(!compare(previousSpot, actual.spot), "The joint must actually move the local shadow.")
                        }
                        if step == 2 {
                            #expect(projection != previousProjection, "The camera move must change a cascade projection in this frame.")
                            #if os(Windows)
                            #expect(writes == previousStaticWrites, "Moving a cascaded camera must draw directly into the output atlas.")
                            #else
                            #expect(writes > previousStaticWrites, "The new camera projection must rebuild its cascades.")
                            #endif
                        }
                        if step == 4 {
                            #expect(!compare(previousSpot, actual.spot), "The light must actually move the local shadow.")
                            #if os(Windows)
                            #expect(writes > previousStaticWrites, "Two stationary frames must restore static cascade reuse.")
                            #endif
                        }
                        if step == 5 {
                            #expect(!compare(previousSun, actual.sun), "The GPU write must actually remove the static caster's shadow.")
                        }
                        if step == 6 { #expect(writes > previousStaticWrites, "A new atlas must rasterize the current static casters.") }
                        previousStaticWrites = writes
                        previousProjection = projection
                        previousSun = actual.sun
                        previousSpot = actual.spot
                    }
                }
            #endif

            @Test
        func deferredProxyKeepsActualAtlasUntilSourceCameraIsRemoved() async throws {
            let scene = try await Self.fixture()
            try await Self.completeFrame(scene, frames: 4)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let sourceID = scene.camera.id
            let targets = try #require(world.getResource(ExtractedCameraRenderViewTargets.self))
            #expect(targets.activeCameraIDs.contains(sourceID))
            let original = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(original.allocator.slots.count == 4 && original.faceDigests.count == 4)
            #expect(original.renderedFaces == 0 && original.reusedFaces == 4)
            let atlas = try #require(original.color), depth = try #require(original.depth)
            let proxy = try #require(world.getEntities().first { $0.components[ExtractedCameraSource.self]?.entityId == sourceID })
            let camera = try #require(proxy.components[Camera.self])
            let uniform = try #require(proxy.components[GlobalViewUniform.self])
            proxy.components[Camera.self] = nil
            proxy.components[GlobalViewUniform.self] = nil
            let node = LocalShadow3DRenderNode()
            // This is the production update that used to retire an active camera's atlas during backpressure.
            for _ in 0..<3 { node.update(from: world) }
            let retained = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(retained.color === atlas && retained.depth === depth)
            #expect(retained.faceDigests == original.faceDigests && retained.faceMatrixDigests == original.faceMatrixDigests)
            #expect(retained.sceneDigest == original.sceneDigest && retained.allocator.slots == original.allocator.slots)
            proxy.components[Camera.self] = camera
            proxy.components[GlobalViewUniform.self] = uniform
            try await Self.completeFrame(scene)
            let resumed = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(resumed.color === atlas && resumed.depth === depth)
            #expect(resumed.renderedFaces == 0 && resumed.reusedFaces == 4,
                "Resuming extraction must reuse the cached faces rather than allocate and redraw the atlas.")
            scene.camera.components[Camera.self] = nil
            try await scene.app.update()
            node.update(from: world)
            #expect(try #require(world.getResource(ExtractedCameraRenderViewTargets.self)).activeCameraIDs.contains(sourceID) == false)
            #expect(world.getResource(LocalShadow3DViews.self)?.entries[sourceID] == nil,
                "Authoritative camera deletion must still retire the cached atlas.")
        }

        @Test
        func cameraTemporalAndMeshletChangesKeepStaticLightFaces() async throws {
            let scene = try await Self.fixture()
            try await Self.completeFrame(scene, frames: 4)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let original = try #require(world.getResource(LocalShadow3DViews.self)?.entries[scene.camera.id])
            let atlas = try #require(original.color), depth = try #require(original.depth)
            let scales: [Float?] = [0.5, 0.75, nil, 0.5]
            for (index, scale) in scales.enumerated() {
                var camera = try #require(scene.camera.components[Camera.self])
                camera.temporalUpscaling = scale.map { .init(renderScale: $0, method: .portable) }
                scene.camera.components[Camera.self] = camera
                scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: Float(index) * 0.01), position: [0, 0, -10])
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.meshVisibility.meshletLODPixelError = index.isMultiple(of: 2) ? 0 : 2
                scene.camera.components[Environment3D.self] = environment
                try await Self.completeFrame(scene)
                let retained = try #require(world.getResource(LocalShadow3DViews.self)?.entries[scene.camera.id])
                #expect(retained.color === atlas && retained.depth === depth)
                #expect(retained.sceneDigest == original.sceneDigest && retained.faceDigests == original.faceDigests)
                #expect(retained.renderedFaces == 0 && retained.reusedFaces == 4,
                    "Camera motion, temporal input scale and meshlet LOD settings cannot dirty static local-light faces.")
            }
        }
    }
}
#endif
