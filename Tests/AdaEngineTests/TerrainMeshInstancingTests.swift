@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("A shared placement component extracts and draws multiple transforms without per-placement scene entities")
    func extractsSharedTerrainMeshInstances() async throws {
        let app = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Prototype triangle")
        descriptor.positions = MeshBuffer([Vector3(0, 0.5, 0), Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0)])
        descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, 1), count: 3))
        descriptor.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [descriptor], renderDevice: device)
        let material = PBRMaterial()
        material.baseColorFactor = [0.5, 0.5, 0.5, 1]
        var instances: [Mesh3DInstance] = []
        for index in 0..<4 {
            let pose = Transform3D(translation: Vector3(Float(index * 2), 0, 0))
            let color = Vector4(1, Float(index + 1) / 4, 1, 1)
            instances.append(Mesh3DInstance(id: UInt64(index + 1), transform: pose, color: color))
        }
        let parent = app.main.spawn("Environment") { Transform(scale: [-1, 2, 1], position: [3, 4, 5]) }
        let owner = app.main.spawn("Placement cell") {
            Transform(); Mesh3DInstancesComponent(mesh: mesh, materials: [material], instances: instances)
        }
        parent.addChild(owner)
        await app.main.runScheduler(.preUpdate)
        await app.main.runScheduler(.postUpdate)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        await render.runScheduler(.extract)
        let sources = try #require(render.getResource(ExtractedMesh3DSources.self)).meshes
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.entity == owner.id)
        #expect(source.instances == instances)
        #expect(app.main.getEntities().count == 2)
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        lists.prepare(
            sources: sources,
            view: owner.id,
            pass: -1,
            viewMatrix: .identity,
            projection: .identity,
            cullingProjection: .identity,
            settings: .init(frustumCulling: false, lod: false, distanceCulling: false),
            device: device,
            materials: &uniforms
        )
        #expect(lists.count(view: owner.id, pass: -1).visibleMeshes == 4)
        #expect(lists.items(view: owner.id, pass: -1).count == 1)
        #expect(lists.items(view: owner.id, pass: -1).first?.batchRange == 0..<4)
        let buffer = try #require(lists.buffers(view: owner.id, pass: -1).instances?.buffer)
        try #require(buffer.length >= instances.count * MemoryLayout<Flat3DInstanceData>.stride)
        let rows = instances.indices.map { index in
            unsafe buffer.contents().load(fromByteOffset: index * MemoryLayout<Flat3DInstanceData>.stride, as: Flat3DInstanceData.self)
        }
        #expect(rows.count == 4)
        for index in instances.indices where rows.indices.contains(index) {
            #expect(rows[index].modelMatrix == source.transform * instances[index].transform)
            #expect(rows[index].color == material.baseColorFactor * instances[index].color)
        }
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedMesh3DSources.self)?.meshes.count == 1)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Portable tracing includes every transform in a static mesh batch and invalidates it after an instance edit")
    func tracesEverySharedMeshInstance() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Traced prototype")
        descriptor.positions = MeshBuffer([Vector3(0, 0.5, 0), Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0)])
        descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, 1), count: 3))
        descriptor.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [descriptor], renderDevice: device)
        let material = PBRMaterial()
        var source = Mesh3DRenderSource(entity: 1, drawPass: Model3DDrawPass(), mesh: mesh, materials: [material], transform: .identity, bounds: nil)
        source.instances = [
            Mesh3DInstance(id: 1, transform: Transform3D(translation: [0, 0, 0])),
            Mesh3DInstance(id: 2, transform: Transform3D(translation: [2, 0, 0])),
            Mesh3DInstance(id: 3, transform: Transform3D(translation: [4, 0, 0])),
            Mesh3DInstance(id: 4, transform: Transform3D(translation: [6, 0, 0])),
        ]
        var scene = PathTracing3DScene()
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.triangleCount == 4)
        let generation = scene.generation
        source.instances?[0].transform = Transform3D(translation: [0, 3, 0])
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.generation == generation + 1)
        #expect(scene.triangleCount == 4)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Instanced GPU visibility bounds contain a larger selected LOD")
    func instanceOcclusionUsesSelectedLODBounds() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        func triangle(_ scale: Float) -> Mesh {
            var descriptor = MeshDescriptor(name: "LOD triangle")
            descriptor.positions = MeshBuffer([Vector3(0, scale / 2, 0), Vector3(-scale / 2, -scale / 2, 0), Vector3(scale / 2, -scale / 2, 0)])
            descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, 1), count: 3))
            descriptor.indicies = [0, 1, 2]
            return Mesh.generate(from: [descriptor], renderDevice: device)
        }
        let base = triangle(1), alternative = triangle(8)
        var source = Mesh3DRenderSource(
            entity: 17,
            drawPass: Model3DDrawPass(),
            mesh: base,
            materials: [PBRMaterial()],
            transform: Transform3D(translation: [2, 0, 0]),
            bounds: nil,
            alternatives: [alternative],
            thresholds: [0.5]
        )
        source.instances = [Mesh3DInstance(id: 91, transform: Transform3D(translation: [3, 0, 0]))]
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        let view = Transform3D(translation: [0, 0, 1_000])
        let projection = Transform3D.perspective(fieldOfView: .degrees(90), aspectRatio: 1, zNear: 0.1, zFar: 10_000)
        lists.prepare(
            sources: [source],
            view: 1,
            pass: -1,
            viewMatrix: view,
            projection: projection,
            cullingProjection: projection * view,
            settings: .init(frustumCulling: false, lod: true, distanceCulling: false, gpuOcclusion: true),
            device: device,
            materials: &uniforms
        )
        #expect(lists.count(view: 1, pass: -1).lodInstances[1] == 1)
        let candidate = try #require(lists.gpuCandidates(view: 1, pass: -1).first)
        let expected = MeshVisibility3DMath.transformed(alternative.bounds, by: source.transform * Transform3D(translation: [3, 0, 0]))
        #expect(candidate.minimum.x <= expected.min.x && candidate.minimum.y <= expected.min.y)
        #expect(candidate.maximum.x >= expected.max.x && candidate.maximum.y >= expected.max.y)
    }

    @Test("An explicitly empty extracted placement list invalidates an ordinary mesh shadow digest")
    func emptyInstancesInvalidateShadowDigest() async throws {
        _ = try await makeApp()
        let mesh = Mesh.generateCube(renderDevice: unsafe RenderEngine.shared.renderDevice)
        var source = Mesh3DRenderSource(entity: 11, drawPass: Model3DDrawPass(), mesh: mesh, materials: [PBRMaterial()], transform: .identity, bounds: mesh.bounds)
        let ordinary = try #require(ShadowSceneDigest3D.compute(sources: [source], usesLOD: false))
        source.instances = []
        let empty = try #require(ShadowSceneDigest3D.compute(sources: [source], usesLOD: false))
        #expect(empty != ordinary)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Removing placements releases LOD history while an offscreen live placement retains its selection")
    func removedInstanceLODHistoryIsReleased() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateCube(renderDevice: device)
        var source = Mesh3DRenderSource(
            entity: 12,
            drawPass: Model3DDrawPass(),
            mesh: mesh,
            materials: [PBRMaterial()],
            transform: .identity,
            bounds: mesh.bounds,
            alternatives: [mesh],
            thresholds: [0.5]
        )
        source.instances = [Mesh3DInstance(id: 41), Mesh3DInstance(id: 42)]
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        func prepare(_ sources: [Mesh3DRenderSource], culling: Bool = false) {
            uniforms.beginFrame()
            lists.prepare(
                sources: sources,
                view: 1,
                pass: -1,
                viewMatrix: .identity,
                projection: .identity,
                cullingProjection: .identity,
                settings: .init(frustumCulling: culling, lod: true, distanceCulling: false),
                device: device,
                materials: &uniforms
            )
        }
        prepare([source])
        #expect(lists.cachedLODSelectionCount == 2)
        source.instances = [Mesh3DInstance(id: 42, transform: Transform3D(translation: [100, 0, 0]))]
        prepare([source], culling: true)
        #expect(lists.count(view: 1, pass: -1).visibleMeshes == 0)
        #expect(lists.cachedLODSelectionCount == 1)
        // Removed IDs cannot accumulate over repeated scatter/erase strokes.
        for id in UInt64(100)..<120 {
            source.instances = [Mesh3DInstance(id: id)]
            prepare([source])
            #expect(lists.cachedLODSelectionCount == 1)
        }
        prepare([])
        #expect(lists.cachedLODSelectionCount == 0)
    }

    @Test("Placement reorder preserves previous transforms by stable ID and removing the component clears extraction")
    func instanceReorderAndRemoval() async throws {
        let app = try await makeApp()
        let mesh = Mesh.generateCube(renderDevice: unsafe RenderEngine.shared.renderDevice)
        let first = Mesh3DInstance(id: 51, transform: Transform3D(translation: [1, 0, 0]))
        let second = Mesh3DInstance(id: 52, transform: Transform3D(translation: [2, 0, 0]))
        let owner = app.main.spawn {
            Transform(); Mesh3DInstancesComponent(mesh: mesh, materials: [PBRMaterial()], instances: [first, second])
        }
        await app.main.runScheduler(.postUpdate)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        render.insertResource(MainWorld(world: app.main))
        await render.runScheduler(.extract)
        var changed = second
        changed.transform = Transform3D(translation: [9, 0, 0])
        owner.components[Mesh3DInstancesComponent.self]?.instances = [changed, first, Mesh3DInstance(id: 53)]
        await render.runScheduler(.extract)
        let source = try #require(render.getResource(ExtractedMesh3DSources.self)?.meshes.first)
        #expect(source.instances?.map(\.id) == [52, 51, 53])
        #expect(source.previousInstances?.map(\.transform) == [second.transform, first.transform, .identity])
        await render.runScheduler(.extract)
        let settled = try #require(render.getResource(ExtractedMesh3DSources.self)?.meshes.first)
        #expect(settled.previousInstances == settled.instances)
        owner.components.remove(Mesh3DInstancesComponent.self)
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedMesh3DSources.self)?.meshes.isEmpty == true)
    }
}
