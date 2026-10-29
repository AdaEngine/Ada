@_spi(Internal) import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Testing

@MainActor
@Suite("Incremental mesh extraction")
struct Model3DIncrementalExtractionTests {
    @Test("Render nodes release geometry snapshots so moving one mesh keeps the source buffer")
    func renderNodesDoNotRetainSourceArray() async throws {
        let (app, render) = try await makeApp(core3D: true)
        let mesh = cube(), material = PBRMaterial()
        let entities = (0..<128).map { _ in app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: .identity) } }
        await render.runScheduler(.extract)
        let main = Main3DRenderNode(), directional = DirectionalShadow3DRenderNode(), local = LocalShadow3DRenderNode()
        main.update(from: render)
        directional.update(from: render)
        local.update(from: render)
        func address() throws -> UInt {
            try sources(render).withUnsafeBufferPointer { UInt(bitPattern: try #require($0.baseAddress)) }
        }
        let original = try address()
        entities[0].components[GlobalTransform.self] = GlobalTransform(matrix: Transform3D(translation: [10, 0, 0]))
        await render.runScheduler(.extract)
        #expect(try address() == original)
        #expect(try sources(render).first?.transform.origin.x == 10)
        // Keep all three nodes alive across extraction, like the real render graph.
        withExtendedLifetime((main, directional, local)) {}
    }

    @Test("Camera-only frames retain geometry and its array; moving objects settle their motion history")
    func cameraFramesAndMotionHistory() async throws {
        let (app, render) = try await makeApp()
        let mesh = cube()
        let material = PBRMaterial()
        let entities = (0..<128).map { index in
            app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: Transform3D(translation: [Float(index), 0, 3])) }
        }
        let camera = app.main.spawn { Camera(); Transform() }
        await render.runScheduler(.extract)
        let initial = try sources(render)
        let builds = render.getResource(Model3DExtractionCache.self)?.geometryBuildCount
        for index in 0..<16 {
            camera.components[Transform.self] = Transform(position: [Float(index), 3, -6])
            await render.runScheduler(.extract)
        }
        let retained = try sources(render)
        #expect(builds == 128)
        #expect(render.getResource(Model3DExtractionCache.self)?.geometryBuildCount == builds)
        initial.withUnsafeBufferPointer { first in
            retained.withUnsafeBufferPointer { second in #expect(first.baseAddress == second.baseAddress) }
        }
        let old = try #require(initial.first { $0.entity == entities[0].id })
        let moved = Transform3D(translation: [12, 4, 8])
        entities[0].components[GlobalTransform.self] = GlobalTransform(matrix: moved)
        await render.runScheduler(.extract)
        let moving = try #require(try sources(render).first { $0.entity == entities[0].id })
        #expect(moving.transform == moved && moving.previousTransform == old.transform)
        #expect(moving.bounds?.center == mesh.bounds.center + moved.origin)
        #expect(initial.first?.transform == old.transform)
        await render.runScheduler(.extract)
        let stopped = try #require(try sources(render).first { $0.entity == entities[0].id })
        #expect(stopped.previousTransform == stopped.transform)
        #expect(render.getResource(Model3DExtractionCache.self)?.geometryBuildCount == builds)
    }

    @Test("In-tick component and mutable-query edits refresh geometry, bindings, LOD and culling")
    func sourceAndLODEdits() async throws {
        let (app, render) = try await makeApp()
        let red = PBRMaterial(), green = PBRMaterial()
        let mesh = cube(), wider = cube(size: [4, 4, 4])
        let entity = app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [red]); GlobalTransform(matrix: .identity) }
        await render.runScheduler(.extract)
        let tick = app.main.currentTick
        let edit = Query<Ref<Mesh3DComponent>>(from: app.main)
        edit.forEach { component in
            component.wrappedValue.mesh = wider
            component.wrappedValue.materials[0] = green
            component.wrappedValue.castShadows = false
            component.wrappedValue.receiveShadows = false
        }
        entity.components[MeshLOD3DComponent.self] = MeshLOD3DComponent(alternatives: [mesh], screenThresholds: [0.2], maximumDistance: 50)
        entity.components[NoFrustumCulling.self] = NoFrustumCulling()
        await render.runScheduler(.extract)
        let changed = try #require(try sources(render).first)
        #expect(app.main.currentTick == tick)
        #expect(changed.mesh.bounds == wider.bounds && changed.materials.first === green)
        #expect(!changed.castShadows && !changed.receiveShadows && changed.forceVisible)
        #expect(changed.alternatives.count == 1 && changed.thresholds == [0.2] && changed.maximumDistance == 50)
        Query<Ref<MeshLOD3DComponent>>(from: app.main).forEach { lod in
            lod.wrappedValue.alternatives.append(wider)
            lod.wrappedValue.screenThresholds = [0.3, 0.1]
            lod.wrappedValue.fadeDistance = 7
        }
        await render.runScheduler(.extract)
        let levels = try #require(try sources(render).first)
        #expect(levels.alternatives.count == 2 && levels.thresholds == [0.3, 0.1] && levels.fadeDistance == 7)
        // Material objects stay live even when their owning component is unchanged.
        green.baseColorFactor = [0.1, 0.8, 0.3, 1]
        entity.components.remove(MeshLOD3DComponent.self)
        entity.components.remove(NoFrustumCulling.self)
        await render.runScheduler(.extract)
        let removed = try #require(try sources(render).first)
        #expect(removed.alternatives.isEmpty && removed.maximumDistance == nil && !removed.forceVisible)
        #expect((removed.materials.first as? PBRMaterial)?.baseColorFactor == green.baseColorFactor)
    }

    @Test("Hidden, removed and newly spawned meshes compact without stale slots")
    func membershipChanges() async throws {
        let (app, render) = try await makeApp()
        let mesh = cube(), material = PBRMaterial()
        let entities = (0..<12).map { _ in app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: .identity) } }
        await render.runScheduler(.extract)
        entities[2].components[Visibility.self] = .hidden
        entities[7].components.remove(Mesh3DComponent.self)
        await render.runScheduler(.extract)
        #expect(Set(try sources(render).map(\.entity)) == Set(entities.enumerated().filter { $0.offset != 2 && $0.offset != 7 }.map { $0.element.id }))
        entities[2].components.remove(Visibility.self)
        let extra = app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: Transform3D(translation: [50, 0, 0])) }
        await render.runScheduler(.extract)
        let result = try sources(render)
        #expect(result.count == 12 && Set(result.map(\.entity)).count == 12)
        #expect(result.first { $0.entity == extra.id }?.transform.origin.x == 50)
        for entity in entities { entity.components.remove(Mesh3DComponent.self) }
        extra.components.remove(Mesh3DComponent.self)
        await render.runScheduler(.extract)
        #expect(try sources(render).isEmpty)
    }

    private func cube(size: Vector3 = .one) -> Mesh {
        Mesh.generateCube(size: size, renderDevice: unsafe RenderEngine.shared.renderDevice)
    }

    @Test("Shared material tables keep newly assigned and hidden animated graphs live, and release removed bindings")
    func sharedMaterialClocks() async throws {
        let (app, render) = try await makeApp()
        let mesh = cube(), material = PBRMaterial()
        let entities = (0..<24).map { _ in app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: .identity) } }
        await render.runScheduler(.extract)
        let graph = ShaderGraph(target: .pbrSurface, output: "output", nodes: [
            .init(id: "time", operation: .time), .init(id: "output", operation: .output, inputs: ["roughness": .init("time")])
        ])
        let animated = try ShaderGraphMaterial(source: .init(graph: graph))
        material.graphMaterial = animated
        var clock = ShaderGraphClock()
        clock.advance(delta: 1)
        render.insertResource(clock)
        await render.runScheduler(.extract)
        #expect(animated.valueRevision > 0)
        let firstRevision = animated.valueRevision
        for entity in entities { entity.components[Visibility.self] = .hidden }
        clock.advance(delta: 1)
        render.insertResource(clock)
        await render.runScheduler(.extract)
        #expect(try sources(render).isEmpty)
        #expect(animated.valueRevision > firstRevision)
        animated.setTime(3)
        let manual = animated.valueRevision
        clock.advance(delta: 1)
        render.insertResource(clock)
        await render.runScheduler(.extract)
        #expect(animated.valueRevision == manual)
        for entity in entities { entity.components.remove(Mesh3DComponent.self) }
        material.graphMaterial = try ShaderGraphMaterial(source: .init(graph: graph))
        let unbound = try #require(material.graphMaterial)
        clock.advance(delta: 1)
        render.insertResource(clock)
        await render.runScheduler(.extract)
        #expect(unbound.valueRevision == 0)
    }

    @Test("Replacing the main world cannot reuse slots for colliding numeric entity IDs")
    func replacementWorld() async throws {
        let (app, render) = try await makeApp()
        let mesh = cube(), material = PBRMaterial()
        let first = app.main.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: .identity) }
        await render.runScheduler(.extract)
        #expect(try sources(render).count == 1)
        let replacement = World()
        render.insertResource(MainWorld(world: replacement))
        await render.runScheduler(.extract)
        #expect(try sources(render).isEmpty)
        let next = replacement.spawn { Mesh3DComponent(mesh: mesh, materials: [material]); GlobalTransform(matrix: Transform3D(translation: [15, 0, 0])) }
        #expect(first.id == next.id)
        await render.runScheduler(.extract)
        #expect(try sources(render).first?.transform.origin.x == 15)
    }

    private func makeApp(core3D: Bool = false) async throws -> (AppWorlds, World) {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        if core3D { app.addPlugin(Core3DPlugin()) }
        try await app.build()
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        return (app, render)
    }

    private func sources(_ world: World) throws -> [Mesh3DRenderSource] {
        try #require(world.getResource(ExtractedMesh3DSources.self)).meshes
    }
}
