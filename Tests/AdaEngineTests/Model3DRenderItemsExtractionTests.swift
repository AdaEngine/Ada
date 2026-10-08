import AdaEngine
@_spi(Internal) @testable import AdaApp
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite("Model3D render item extraction")
struct Model3DRenderItemsExtractionTests {

    @Test("opaque 3D render items survive render-world pre-update")
    func opaque3DRenderItemsSurviveRenderWorldPreUpdate() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = AppWorlds(main: World())
        app
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(Model3DPlugin())

        try await app.build()

        let mesh = Self.makeTriangleMesh()
        let material = PBRMaterial()
        material.baseColorFactor = [0.2, 0.4, 0.6, 1]
        material.metallicFactor = 0.75
        material.roughnessFactor = 0.25
        let meshEntity = app.main.spawn("Cube 1") {
            Mesh3DComponent(mesh: mesh, materials: [material])
            Transform(position: [1, 2, 3])
        }
        app.main.spawn("Cube 2") {
            Mesh3DComponent(mesh: mesh, materials: [material])
            Transform(position: [4, 5, 6])
        }
        app.main.spawn("Key Light") {
            DirectionalLightComponent(
                radiance: [1, 0.8, 0.6],
                intensity: 2.5,
                castShadows: true,
                shadowDistance: 42,
                shadowBias: 0.001,
                shadowSlopeBias: 0.004
            )
            Transform()
        }

        await app.main.runScheduler(.preUpdate)

        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        renderWorld.insertResource(MainWorld(world: app.main))
        await renderWorld.runScheduler(.extract)

        let extractedItems = try #require(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self))
        #expect(extractedItems.items.count == 1)
        #expect(extractedItems.items.first?.entity == meshEntity.id)
        #expect(extractedItems.items.first?.batchRange == 0..<2)
        #expect(material.baseColorFactor == [0.2, 0.4, 0.6, 1])
        #expect(material.metallicFactor == 0.75)
        #expect(material.roughnessFactor == 0.25)

        let extractedLighting = try #require(renderWorld.getResource(ExtractedLighting3D.self))
        let directionalLight = try #require(extractedLighting.directionalLight)
        #expect(directionalLight.directionToLight == [0, 0, -1])
        #expect(directionalLight.radiance == [1, 0.8, 0.6])
        #expect(directionalLight.intensity == 2.5)
        #expect(directionalLight.castsShadows)
        #expect(directionalLight.shadowDistance == 42)
        #expect(directionalLight.shadowBias == 0.001)
        #expect(directionalLight.shadowSlopeBias == 0.004)

        await renderWorld.runScheduler(.preUpdate)

        let preparedItems = try #require(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self))
        #expect(preparedItems.items.count == 1)
        #expect(preparedItems.items.first?.entity == meshEntity.id)
    }

    @Test("mesh shadow flags split batches and survive extraction")
    func meshShadowFlagsSplitBatchesAndSurviveExtraction() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = AppWorlds(main: World())
        app
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(Model3DPlugin())

        try await app.build()

        let mesh = Self.makeTriangleMesh()
        let material = PBRMaterial()
        let caster = app.main.spawn("Caster") {
            Mesh3DComponent(mesh: mesh, materials: [material])
            Transform()
        }
        let satellite = app.main.spawn("Satellite") {
            Mesh3DComponent(
                mesh: mesh,
                materials: [material],
                castShadows: false,
                receiveShadows: false
            )
            Transform(position: [1, 0, 0])
        }

        await app.main.runScheduler(.preUpdate)

        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        renderWorld.insertResource(MainWorld(world: app.main))
        await renderWorld.runScheduler(.extract)

        let extractedItems = try #require(renderWorld.getResource(RenderItems<Opaque3DRenderItem>.self))
        #expect(extractedItems.items.count == 2)

        let casterItem = try #require(extractedItems.items.first { $0.entity == caster.id })
        #expect(casterItem.castShadows)
        #expect(casterItem.receiveShadows)
        #expect(casterItem.batchRange == 0..<1)

        let satelliteItem = try #require(extractedItems.items.first { $0.entity == satellite.id })
        #expect(!satelliteItem.castShadows)
        #expect(!satelliteItem.receiveShadows)
        #expect(satelliteItem.batchRange == 1..<2)
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }

    private static func makeTriangleMesh() -> Mesh {
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Triangle")
        descriptor.positions = MeshBuffer([
            Vector3(0, 0.5, 0),
            Vector3(-0.5, -0.5, 0),
            Vector3(0.5, -0.5, 0)
        ])
        descriptor.normals = MeshBuffer([
            Vector3(0, 0, 1),
            Vector3(0, 0, 1),
            Vector3(0, 0, 1)
        ])
        descriptor.indicies = [0, 1, 2]
        return Mesh.generate(from: [descriptor], renderDevice: device)
    }
}

@Suite("Directional shadow 3D math")
struct DirectionalShadow3DMathTests {
    @Test("shadow projection centers the camera coverage volume")
    func shadowProjectionCentersCameraCoverageVolume() {
        let cameraWorld = Transform3D(translation: [0, 0, -10])
        let distance: Float = 30
        let center = Vector3(0, 0, -10) + Vector3(0, 0, 1) * (distance * 0.5)
        let viewProjection = DirectionalShadow3DMath.makeViewProjection(
            cameraViewMatrix: cameraWorld.inverse,
            directionToLight: Vector3(0.5, 1, -0.5).normalized,
            shadowDistance: distance
        )

        let projectedCenter = viewProjection * Vector4(center, 1)
        let normalizedTexelSize = 2 / Float(DirectionalShadow3D.resolution)
        #expect(Swift.abs(projectedCenter.x) <= normalizedTexelSize * 0.5)
        #expect(Swift.abs(projectedCenter.y) <= normalizedTexelSize * 0.5)
        #expect(projectedCenter.z > 0)
        #expect(projectedCenter.z < projectedCenter.w)
    }

    @Test("sub-texel camera movement keeps the shadow projection stable")
    func subTexelCameraMovementKeepsShadowProjectionStable() {
        let distance: Float = 30
        let resolution = DirectionalShadow3D.resolution
        let worldUnitsPerTexel = distance / Float(resolution)
        let directionToLight = Vector3(0, 1, -1).normalized
        let firstCameraWorld = Transform3D(translation: [0, 0, -10])
        let secondCameraWorld = Transform3D(
            translation: [worldUnitsPerTexel * 0.2, 0, -10]
        )

        let firstProjection = DirectionalShadow3DMath.makeViewProjection(
            cameraViewMatrix: firstCameraWorld.inverse,
            directionToLight: directionToLight,
            shadowDistance: distance,
            shadowMapResolution: resolution
        )
        let secondProjection = DirectionalShadow3DMath.makeViewProjection(
            cameraViewMatrix: secondCameraWorld.inverse,
            directionToLight: directionToLight,
            shadowDistance: distance,
            shadowMapResolution: resolution
        )

        #expect(firstProjection == secondProjection)
    }
}
