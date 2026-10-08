@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@testable import AdaCorePipelines
@testable import AdaECS

@Suite
struct LocalLighting3DMathTests {
    @Test
    func finiteRangeInverseSquareAndConeFalloff() {
        #expect(LocalLighting3DMath.attenuation(distance: 10, range: 10) == 0)
        #expect(LocalLighting3DMath.attenuation(distance: 12, range: 10) == 0)
        #expect(LocalLighting3DMath.attenuation(distance: 1, range: 0) == 0)
        #expect(LocalLighting3DMath.attenuation(distance: .nan, range: 10) == 0)
        #expect(LocalLighting3DMath.attenuation(distance: 0, range: 10).isFinite)
        let a = LocalLighting3DMath.attenuation(distance: 1, range: 100)
        let b = LocalLighting3DMath.attenuation(distance: 2, range: 100)
        #expect(abs(a / b - 4) < 0.001)
        let cosines = LocalLighting3DMath.coneCosines(inner: 20, outer: 35)
        #expect(LocalLighting3DMath.coneAttenuation(cosine: cosines.x, inner: 20, outer: 35) == 1)
        #expect(LocalLighting3DMath.coneAttenuation(cosine: cosines.y, inner: 20, outer: 35) == 0)
        #expect(LocalLighting3DMath.coneAttenuation(cosine: -1, inner: 20, outer: 35) == 0)
        let safe = LocalLighting3DMath.coneCosines(inner: 90, outer: .nan)
        #expect(safe.x > safe.y && safe.x.isFinite)
    }

    @Test
    func cubeFacesAndSpotProjectionCoverTheirLightVolume() {
        let id = World().spawn().id
        let light = ExtractedLocalLight3D(entity: id, kind: .point, position: [2, 3, 4], range: 20)
        let matrices = LocalLighting3DMath.shadowProjections(light)
        #expect(matrices.count == 6)
        let rays: [Vector3] = [[1, 0.2, 0.1], [-1, 0.2, 0.1], [0.2, 1, 0.1], [0.2, -1, 0.1], [0.2, 0.1, 1], [0.2, 0.1, -1]]
        for (face, ray) in rays.enumerated() {
            #expect(LocalLighting3DMath.pointFace(direction: ray) == face)
            let clip = matrices[face] * Vector4(light.position + ray * 5, 1)
            #expect(clip.w > 0 && abs(clip.x) < clip.w && abs(clip.y) < clip.w && clip.z > 0 && clip.z < clip.w)
        }
        let spot = ExtractedLocalLight3D(entity: id, kind: .spot, position: [0, 4, 0], direction: [0, -1, 0], range: 10, outerConeAngle: 35)
        let matrix = LocalLighting3DMath.shadowProjections(spot)[0]
        let clip = matrix * Vector4(0, 0, 0, 1)
        #expect(abs(clip.x) < 0.001 && abs(clip.y) < 0.001 && clip.z > 0 && clip.z < clip.w)
    }

    @Test
    func perCameraSelectionIsBoundedAndShadowSlotsSurviveRankingChanges() {
        let world = World()
        var lights: [ExtractedLocalLight3D] = []
        for index in 0..<40 { lights.append(.init(entity: world.spawn().id, kind: .point, position: [Float(index) / 10, 0, 5], range: 5)) }
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 100)
        let selected = LocalLighting3DMath.select(lights, viewProjection: projection, cameraPosition: .zero)
        #expect(selected.count == 32)
        let otherView = Transform3D(translation: [-100, 0, 0])
        #expect(LocalLighting3DMath.select(lights, viewProjection: projection * otherView, cameraPosition: [100, 0, 0]).isEmpty)
        var allocator = LocalShadow3DAllocator()
        allocator.select(Array(lights.prefix(4)), cameraPosition: .zero, budget: 2)
        let first = allocator.slots
        allocator.select(Array(lights.prefix(2).reversed()), cameraPosition: [1, 0, 0], budget: 2)
        #expect(allocator.slots == first)
        lights[3].shadowPriority = 10
        allocator.select(Array(lights.prefix(4)), cameraPosition: .zero, budget: 2)
        #expect(allocator.slots[lights[3].entity] != nil)
        #expect(allocator.slots.count == 2)
        allocator.select([lights[3]], cameraPosition: .zero, budget: 1)
        #expect(allocator.slots == [lights[3].entity: 0])
        allocator.select([], cameraPosition: .zero, budget: 2)
        #expect(allocator.slots.isEmpty)
    }

    @Test
    func legacyComponentPayloadsAndNewSettingsRoundTrip() throws {
        let old = Data(#"{"radiance":[1,0.5,0.2],"intensity":3,"castShadows":false}"#.utf8)
        let point = try JSONDecoder().decode(PointLightComponent.self, from: old)
        let spot = try JSONDecoder().decode(SpotLightComponent.self, from: old)
        #expect(point.range == 10 && !point.castShadows)
        #expect(spot.innerConeAngle == 20 && spot.outerConeAngle == 35)
        let authored = SpotLightComponent(range: 16, innerConeAngle: 12, outerConeAngle: 28, shadowBias: 0.003, shadowPriority: 8)
        let restored = try JSONDecoder().decode(SpotLightComponent.self, from: JSONEncoder().encode(authored))
        #expect(restored.range == 16 && restored.innerConeAngle == 12 && restored.outerConeAngle == 28 && restored.shadowPriority == 8)
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(environment.localShadows.maximumLights == 4)
    }
}

@MainActor
@Suite
struct LocalLighting3DExtractionTests {
    private func setup() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test
    func extractionPreservesAllKindsWorldTransformsAndHiddenHierarchy() async throws {
        try setup()
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        app.main.spawn {
            DirectionalLightComponent(intensity: 2)
            Transform()
        }
        app.main.spawn {
            DirectionalLightComponent(intensity: 0.3, castShadows: false)
            Transform(rotation: Quat(axis: .up, angle: .pi / 2))
        }
        let point = app.main.spawn {
            PointLightComponent(intensity: 5, range: 7)
            Transform(scale: [3, 3, 3], position: [2, 4, 6])
        }
        app.main.spawn {
            SpotLightComponent(intensity: 8, innerConeAngle: 10, outerConeAngle: 25)
            Transform(rotation: Quat(axis: .right, angle: .pi / 2))
        }
        app.main.spawn {
            PointLightComponent(intensity: 0)
            Transform()
        }
        let parent = app.main.spawn {
            Transform()
            Visibility.hidden
        }
        let hidden = app.main.spawn {
            PointLightComponent()
            Transform()
        }
        parent.addChild(hidden)
        await app.main.runScheduler(.preUpdate)
        await app.main.runScheduler(.postUpdate)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        await render.runScheduler(.extract)
        let lights = try #require(render.getResource(ExtractedLighting3D.self))
        #expect(lights.directionalLights.count == 2 && lights.localLights.count == 2 && lights.hasAuthoredLights)
        let selected = try #require(lights.localLights.first { $0.entity == point.id })
        #expect(selected.position == [2, 4, 6] && selected.range == 7)
        #expect(!lights.localLights.contains { $0.entity == hidden.id })
        let spot = try #require(lights.localLights.first { $0.kind == .spot })
        #expect(abs(spot.direction.y + 1) < 0.001)
        point.components[PointLightComponent.self]?.intensity = 0
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedLighting3D.self)?.localLights.count == 1)
    }
    @Test
    func cameraUniformsRemainIndependentAndPreservePackedShaderLayout() throws {
        try setup()
        let device = HeadlessRenderBackend().renderDevice
        let world = World()
        let a = world.spawn().id
        let b = world.spawn().id
        var cache = LocalLighting3DGPUScratch()
        var lights = ExtractedLighting3D()
        var entry = LocalShadow3DViews.Entry()
        entry.lights = [.init(entity: world.spawn().id, kind: .spot, position: [2, 4, 6], direction: [0, -1, 0], range: 8)]
        let first = cache.write(view: a, count: 135, device: device) { packLocalLighting(lights, view: .identity, shadows: entry, into: &$0) }
        let second = cache.write(view: b, count: 135, device: device) {
            packLocalLighting(lights, view: Transform3D(translation: [-1, 0, 0]), shadows: entry, into: &$0)
        }
        #expect(first.buffer !== second.buffer)
        var ibl = IBL3DScratch()
        let leftIBL = ibl.cache.write(IBL3DUniform(inverseView: .identity, parameters: .zero), view: a, device: device)
        let rightIBL = ibl.cache.write(IBL3DUniform(inverseView: Transform3D(translation: [1, 0, 0]), parameters: .zero), view: b, device: device)
        #expect(leftIBL.buffer !== rightIBL.buffer)
        #expect(first.elements[0].y == 1)
        #expect(first.elements[7] == Vector4(2, 4, 6, 8))
        #expect(second.elements[7] == Vector4(1, 4, 6, 8))
        #expect(first.elements[10].w == -1)
        lights.directionalLights = [.init(directionToLight: [0, 1, 0], radiance: .one, intensity: 2), .init(directionToLight: [0, -1, 0], radiance: [0.2, 0.4, 0.6], intensity: 3)]
        var data = [Vector4](repeating: .zero, count: 135)
        packLocalLighting(lights, view: .identity, shadows: nil, into: &data)
        #expect(data[0].x == 1 && data[0].y == 0)
        #expect(data[1] == Vector4(0, -1, 0, 3))
        #expect(data[4] == Vector4(0.2, 0.4, 0.6, 0))
    }

    @Test
    func localShadowGraphKeepsOffscreenCastersAndReusesItsAtlas() async throws {
        try setup()
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Core3DPlugin())
        try await app.build()
        let world = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        let device = HeadlessRenderBackend().renderDevice
        let id = world.spawn().id
        let caster = world.spawn().id
        let mesh = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        let matrix = Transform3D(translation: [4, 0, 5])
        let source = Mesh3DRenderSource(
            entity: caster,
            drawPass: Model3DDrawPass(),
            mesh: mesh,
            materials: [material],
            transform: matrix,
            bounds: MeshVisibility3DMath.transformed(mesh.bounds, by: matrix),
            maximumDistance: 1
        )
        var candidates = ExtractedMesh3DSources()
        candidates.meshes = [source]
        world.insertResource(candidates)
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.insertResource(PBR3DUniforms())
        let skins = world.getRefResource(Skinning3DUniforms.self)
        skins.wrappedValue.beginFrame(device: device)
        let projection = Transform3D.perspective(fieldOfView: .degrees(30), aspectRatio: 1, zNear: 0.1, zFar: 100)
        let view = world.spawn {
            Camera()
            GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection)
            ExtractedCameraSource(entityId: id)
        }
        var lights = ExtractedLighting3D()
        lights.localLights = [.init(entity: world.spawn().id, kind: .point, position: [0, 0, 5], range: 10)]
        world.insertResource(lights)
        var scene = RenderGraph(label: .main3D)
        scene.addNode(LocalShadow3DRenderNode())
        var root = RenderGraph()
        root.addSubgraph(scene, name: .main3D)
        root.addNode(LocalLightTestViewNode(view: view))
        root.update(from: world)
        try await RenderGraphExecutor().execute(root, renderDevice: device, in: world)
        let first = try #require(world.getResource(LocalShadow3DViews.self)?.entries[id])
        #expect(first.allocator.slots.count == 1)
        #expect(world.getResource(VisibleMesh3DLists.self)?.count(view: id, pass: 100).visibleMeshes == 1)
        #expect(!MeshVisibility3DMath.intersects(try #require(source.bounds), viewProjection: projection))
        root.update(from: world)
        try await RenderGraphExecutor().execute(root, renderDevice: device, in: world)
        let second = try #require(world.getResource(LocalShadow3DViews.self)?.entries[id])
        #expect(first.color === second.color && first.depth === second.depth)
        world.insertResource(ExtractedLighting3D())
        root.update(from: world)
        try await RenderGraphExecutor().execute(root, renderDevice: device, in: world)
        #expect(world.getResource(LocalShadow3DViews.self)?.entries[id]?.allocator.slots.isEmpty == true)
    }
}

private struct LocalLightTestViewNode: RenderNode {
    let view: Entity
    func execute(context: inout Context, renderContext _: RenderContext) async throws -> [RenderSlotValue] {
        context.runSubgraph(.main3D, inputs: [], viewEntity: view)
        return []
    }
}
