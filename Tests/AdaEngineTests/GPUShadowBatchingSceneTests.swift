#if canImport(WebGPU) && (os(Windows) || os(macOS))
    @_spi(Internal) @testable import AdaApp
    @testable import AdaCorePipelines
    import AdaECS
    @_spi(Internal) @testable import AdaRender
    @testable import AdaScene
    import AdaTransform
    import AdaUtils
    import Foundation
    import Math
    import Testing

    extension Render3DGPUTests {
        /// GPU-culled shadow casters must produce exactly the frames of the CPU-culled path.
        @MainActor
        @Suite("WebGPU GPU-driven shadow batching", .serialized)
        struct GPUShadowBatchingSceneTests {
            @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_WEBGPU_SCENE_SMOKE"] == "1"))
            func matchesCPUShadowsAcrossLightAndCasterMotion() async throws {
                unsafe RenderEngine.configurations.preferredBackend = .webgpu
                try RenderEngine.setupRenderEngine()
                let engine = try #require(unsafe RenderEngine.shared)
                try #require(engine.type == .webgpu)
                let device = engine.renderDevice
                let app = AppWorlds(main: World())
                app.insertResource(OffscreenRenderWorld())
                    .insertResource(PrimaryWindowId(windowId: RID()))
                    .addPlugin(MainSchedulerPlugin())
                    .addPlugin(TransformPlugin())
                    .addPlugin(RenderWorldPlugin())
                    .addPlugin(CameraPlugin())
                    .addPlugin(AssetsPlugin(filePath: #filePath))
                    .addPlugin(VisibilityPlugin())
                    .addPlugin(ScenePlugin())
                    .addPlugin(Core3DPlugin())
                try await app.build()

                let target = RenderTexture(size: [160, 120], scaleFactor: 1, format: .bgra8)
                var environment = Environment3D(antiAliasing: .none)
                environment.skybox.isEnabled = false
                environment.screenSpaceReflection.isEnabled = false
                environment.shadows.isEnabled = true
                environment.shadows.cascadeCount = 3
                environment.localShadows.isEnabled = true
                environment.localShadows.maximumLights = 2
                let camera = app.main.spawn("Camera", bundle: Camera3D(
                    camera: Camera(renderTarget: target),
                    transform: Transform(rotation: Quat.euler([-0.5, 0, 0]), position: [0, 5, -9]),
                    environment: environment
                ))
                let floorMaterial = PBRMaterial()
                floorMaterial.baseColorFactor = [0.7, 0.7, 0.7, 1]
                app.main.spawn("Floor") {
                    Mesh3DComponent(mesh: Mesh.generateCube(size: [16, 0.2, 16], renderDevice: device), materials: [floorMaterial])
                    Transform(position: [0, -1, 0])
                }
                let singleSided = PBRMaterial()
                singleSided.doubleSided = false
                singleSided.baseColorFactor = [0.8, 0.3, 0.1, 1]
                let doubleSided = PBRMaterial()
                doubleSided.doubleSided = true
                let masked = PBRMaterial()
                masked.alphaMode = .mask
                masked.alphaCutoff = 0.5
                masked.baseColorFactor = [0.2, 0.5, 0.9, 0.4]
                let cube = Mesh.generateCube(size: [0.8, 0.8, 0.8], renderDevice: device)
                let sphere = Mesh.generateSphere(segments: 12, rings: 8, renderDevice: device)
                var movers: [Entity] = []
                for index in 0..<6 {
                    let material = [singleSided, doubleSided, masked][index % 3]
                    let entity = app.main.spawn("Caster \(index)") {
                        Mesh3DComponent(mesh: index.isMultiple(of: 2) ? cube : sphere, materials: [material])
                        Transform(position: [Float(index % 3 - 1) * 2.5, 0.5, Float(index / 3) * 2.5])
                    }
                    movers.append(entity)
                }
                // A caster with level-of-detail meshes and a draw distance stays CPU-culled and shares the faces.
                app.main.spawn("CPU-path caster") {
                    Mesh3DComponent(mesh: sphere, materials: [singleSided])
                    MeshLOD3DComponent(alternatives: [cube], maximumDistance: 60)
                    Transform(position: [1, 1.5, 1.5])
                }
                app.main.spawn("Distance-faded caster") {
                    Mesh3DComponent(mesh: cube, materials: [singleSided])
                    MeshLOD3DComponent(maximumDistance: 12, fadeDistance: 6)
                    Transform(position: [0, 0.6, 1])
                }
                app.main.spawn("Instanced casters") {
                    Mesh3DInstancesComponent(mesh: cube, materials: [singleSided], instances: (0..<5).map {
                        Mesh3DInstance(id: UInt64($0), transform: Transform3D(translation: [Float($0) * 1.4 - 2.8, 0, -3]), color: [1, 1, 1, 0.9])
                    })
                    Transform()
                }
                app.main.spawn("Sun") {
                    DirectionalLightComponent(intensity: 3, castShadows: true)
                    Transform(rotation: Quat.euler([-0.9, 0.4, 0]))
                }
                let lights = (0..<2).map { index in
                    app.main.spawn("Point \(index)") {
                        PointLightComponent(intensity: 25, castShadows: true, range: 12)
                        Transform(position: [Float(index) * 4 - 2, 3, 1])
                    }
                }
                let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
                func frame(gpu: Bool) async throws -> Image {
                    var registry = try #require(render.getResource(ShadowCasterRegistry3D.self))
                    registry.isEnabled = gpu
                    render.insertResource(registry)
                    for _ in 0..<3 { try await app.update() }
                    if gpu {
                        let current = try #require(render.getResource(ShadowCasterRegistry3D.self))
                        #expect(current.hasCasters, "The scene's static casters must take the GPU path")
                        #expect(!current.cpuSources.isEmpty, "The LOD caster must stay on the CPU path in the same passes")
                    }
                    return try #require(try await device.readImage(from: target))
                }
                // A frame without shadows sits between the compared frames, so a dropped GPU submission
                // (which leaves the previous image in the target) cannot pass as a match.
                func unshadowed() async throws -> Image {
                    var settings = try #require(camera.components[Environment3D.self])
                    let original = settings
                    settings.shadows.isEnabled = false
                    settings.localShadows.isEnabled = false
                    camera.components[Environment3D.self] = settings
                    for _ in 0..<2 { try await app.update() }
                    let image = try #require(try await device.readImage(from: target))
                    camera.components[Environment3D.self] = original
                    return image
                }
                func compare(_ scenario: String) async throws {
                    let reference = try await frame(gpu: false)
                    let plain = try await unshadowed()
                    #expect(plain.data != reference.data, "\(scenario) must contain visible shadows")
                    let actual = try await frame(gpu: true)
                    let differing = zip(reference.data, actual.data).filter { $0 != $1 }.count
                    #expect(actual.data == reference.data, "GPU shadow batching changed \(differing) bytes in \(scenario)")
                    if let directory = ProcessInfo.processInfo.environment["ADAENGINE_WEBGPU_SCENE_OUTPUT"] {
                        let folder = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try reference.writePNG(to: folder.appendingPathComponent("\(scenario)-cpu-shadows.png"))
                        try actual.writePNG(to: folder.appendingPathComponent("\(scenario)-gpu-shadows.png"))
                    }
                }
                try await compare("static")

                // The atlas still renders each frame, while the same camera and
                // casters can reuse the prepared lists for all three cascades.
                var directionalOnly = environment
                directionalOnly.localShadows.isEnabled = false
                camera.components[Environment3D.self] = directionalOnly
                try await compare("directional-distance-fade")
                for _ in 0..<2 { try await app.update() }
                let lists = try #require(render.getResource(VisibleMesh3DLists.self))
                #expect(lists.count(view: camera.id, pass: 0).candidates == 1, "Distance-only caster should take the directional GPU path")
                let prepared = lists.preparedPassCount
                let visited = try #require(render.getResource(Model3DExtractionCache.self)).sourceVisitCount
                try await app.update()
                let nextPrepared = try #require(render.getResource(VisibleMesh3DLists.self)).preparedPassCount
                let nextVisited = try #require(render.getResource(Model3DExtractionCache.self)).sourceVisitCount
                #expect(nextPrepared - prepared == 1, "An unchanged scene should prepare the main view only")
                #expect(nextVisited == visited, "An unchanged render source should not be visited by extraction")
                camera.components[Environment3D.self] = environment

                for (index, light) in lights.enumerated() {
                    light.components[Transform.self] = Transform(position: [Float(index) * 3 - 1, 2.5, 2])
                }
                try await compare("lights-moved")
                movers[1].components[Transform.self] = Transform(position: [4, 0.5, 4])
                try await compare("caster-moved")

                // Kept faces must redraw where a GPU-path caster changed, with the GPU path staying on.
                _ = try await frame(gpu: true)
                movers[0].components[Transform.self] = Transform(position: [-3, 0.5, 3])
                let incremental = try await frame(gpu: true)
                let full = try await frame(gpu: false)
                #expect(incremental.data == full.data, "A partly reused atlas must equal a full redraw")

                let sources = try #require(render.getResource(ExtractedMesh3DSources.self)).meshes
                let caster = try #require(sources.first { $0.castShadows && ShadowCasterRegistry3D.isEligible($0) })
                let palette = try #require(render.getResource(Skinning3DUniforms.self)?.identityBuffer)
                var registry = ShadowCasterRegistry3D()
                registry.isEnabled = true
                var materials = PBR3DUniforms()
                materials.beginFrame()
                registry.update(sources: [caster], materials: &materials, identityPalette: palette, device: device)
                #expect(registry.hasCasters)
                materials.beginFrame()
                registry.update(sources: [], materials: &materials, identityPalette: palette, device: device, transformChanges: [])
                #expect(!registry.hasCasters, "A one-frame external override must not seed canonical sparse updates")
            }
        }
    }
#endif
