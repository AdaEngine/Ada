@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("A raster camera leaves another camera's staged forest intact until its last trace owner is removed")
    func rasterCameraDoesNotDiscardAnotherCamerasStagedGeometry() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let material = PBRMaterial()
        let mesh = Mesh.generateCube(renderDevice: device)
        let forest = Mesh3DRenderSource(entity: 6, drawPass: Model3DDrawPass(), mesh: mesh, materials: [material], transform: .identity, bounds: mesh.bounds)
        var tile = forest
        tile.entity = 7
        tile.mesh = Mesh.generateCube(size: [2, 0.5, 2], renderDevice: device)
        var views = PathTracing3DViews()
        views.traceOwners.insert(21)
        var finished = false
        for frame in 0..<5 {
            do {
                try await views.scene.prepare([forest, tile], skinning: nil, device: device, hardwareOrder: true, hardwareTriangleStep: 12)
                finished = true
                break
            } catch PathTracing3DError.preparingGeometry {
                if frame == 0 {
                    #expect(views.scene.preparedVertexCount == 36)
                    var removedDuringPreparation = views
                    removedDuringPreparation.stopTracing(21)
                    #expect(removedDuringPreparation.scene.atlas == nil && removedDuringPreparation.traceOwners.isEmpty)
                }
                views.stopTracing(22)
                #expect(views.scene.atlas != nil)
            }
        }
        #expect(finished && views.scene.triangleCount == 24)
        views.stopTracing(21)
        #expect(views.scene.triangles == nil && views.scene.atlas == nil && views.traceOwners.isEmpty)
    }

    @Test("Replacing a terrain LOD preserves the forest triangle table and prepares only the changed mesh")
    func hardwareTracingRetainsTreesAcrossTerrainLODChanges() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let material = PBRMaterial()
        let tree = Mesh.generateCube(renderDevice: device)
        var forest = Mesh3DRenderSource(entity: 45, drawPass: Model3DDrawPass(), mesh: tree, materials: [material], transform: .identity, bounds: tree.bounds)
        forest.instances = (0..<32).map { Mesh3DInstance(id: UInt64($0)) }
        var tile = forest
        tile.entity = 46
        tile.instances = nil
        tile.mesh = Mesh.generateCube(size: [4, 0.2, 4], renderDevice: device)
        var scene = PathTracing3DScene()
        try await scene.prepare([forest, tile], skinning: nil, device: device, hardwareOrder: true)
        let initialTable = try #require(scene.triangles)
        #expect(scene.preparedVertexCount == 72)
        var coarse = MeshDescriptor(name: "Coarse terrain tile")
        coarse.positions = MeshBuffer([Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(0, 0, 2)])
        coarse.indicies = [0, 1, 2]
        tile.mesh = Mesh.generate(from: [coarse], renderDevice: device)
        try await scene.prepare([tile, forest], skinning: nil, device: device, hardwareOrder: true)
        #expect(scene.preparedVertexCount == 3)
        #expect(scene.triangles === initialTable)
        #expect(scene.triangleCount == 385)
    }

    @Test("Vulkan tracing shares packed mesh triangles across forest placements")
    func hardwareTracingSharesGeometryAcrossInstances() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateCube(renderDevice: device)
        var source = Mesh3DRenderSource(entity: 45, drawPass: Model3DDrawPass(), mesh: mesh, materials: [PBRMaterial()], transform: .identity, bounds: mesh.bounds)
        source.instances = (0..<12_000).map {
            Mesh3DInstance(id: UInt64($0), transform: Transform3D(translation: [Float($0), 0, 0]))
        }
        var scene = PathTracing3DScene()
        try await scene.prepare([source], skinning: nil, device: device, hardwareOrder: true)
        #expect(scene.placements.count == 12_000)
        #expect(scene.preparedVertexCount == 36)
        #expect(scene.triangleCount == 144_000)
        #expect(scene.triangles?.height == 1)
    }

    @Test("Portable tracing transforms referenced vertices only and does not allocate tints for empty parts")
    func terrainTracingBoundsVertexWorkAndEmptyTintAllocations() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "One triangle in a large accessor")
        var positions = [Vector3(0, 1, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)]
        positions.append(contentsOf: repeatElement(Vector3(100, 100, 100), count: 19_997))
        descriptor.positions = MeshBuffer(positions)
        descriptor.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [descriptor], renderDevice: device)
        var source = Mesh3DRenderSource(entity: 46, drawPass: Model3DDrawPass(), mesh: mesh, materials: [PBRMaterial()], transform: .identity, bounds: mesh.bounds)
        source.instances = [Mesh3DInstance(id: 1), Mesh3DInstance(id: 2, transform: Transform3D(translation: [3, 0, 0]))]
        var scene = PathTracing3DScene()
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.triangleCount == 2)
        #expect(scene.preparedVertexCount == 6)
        #expect(scene.geometryBounds?.min.x == -1 && scene.geometryBounds?.max.x == 4)
        descriptor.positions = MeshBuffer(Array(positions.prefix(3)))
        descriptor.indicies = []
        let empty = Mesh.generate(from: [descriptor], renderDevice: device)
        source.mesh = empty
        source.instances = (0..<1_000).map { Mesh3DInstance(id: UInt64($0), color: [Float($0) / 1_000, 1, 1, 1]) }
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.triangleCount == 0)
        #expect(scene.preparedVertexCount == 0)
        #expect(scene.materials?.height == 1)
        var crowded = source
        descriptor.indicies = [0, 1, 2, 0, 1, 2]
        crowded.mesh = Mesh.generate(from: [descriptor], renderDevice: device)
        crowded.instances = (0..<32_769).map { Mesh3DInstance(id: UInt64($0)) }
        var second = crowded
        second.entity = 47
        var limited = PathTracing3DScene()
        do {
            try await limited.prepare([crowded, second], skinning: nil, device: device)
            Issue.record("Aggregate tracing work must be rejected before transforming any vertices")
        } catch is PathTracing3DError {
            #expect(limited.preparedVertexCount == 0)
        }
    }

    @Test("Unrelated ordinary mesh extraction does not sweep static placement LOD history")
    func terrainLODHistoryIgnoresOrdinarySourceRevisions() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        var batch = Mesh3DRenderSource(
            entity: 8,
            drawPass: Model3DDrawPass(),
            mesh: mesh,
            materials: [material],
            transform: .identity,
            bounds: mesh.bounds,
            alternatives: [mesh],
            thresholds: [0.5]
        )
        batch.instances = [Mesh3DInstance(id: 71), Mesh3DInstance(id: 72)]
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        for frame in 0..<8 {
            let ordinary = Mesh3DRenderSource(
                entity: 9,
                drawPass: Model3DDrawPass(),
                mesh: mesh,
                materials: [material],
                transform: Transform3D(translation: [Float(frame), 0, 0]),
                bounds: mesh.bounds,
                alternatives: [mesh],
                thresholds: [0.5]
            )
            uniforms.beginFrame()
            lists.prepare(
                sources: [batch, ordinary],
                view: 1,
                pass: -1,
                viewMatrix: .identity,
                projection: .identity,
                cullingProjection: .identity,
                settings: .init(frustumCulling: false, lod: true, distanceCulling: false),
                device: device,
                materials: &uniforms
            )
            #expect(lists.cachedLODSelectionCount == 3)
            #expect(lists.historyReconciliationCount == 1)
        }
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Nontriangle model parts are filtered once before static placement expansion")
    func terrainTracingSkipsNonTrianglePartsBeforePlacementExpansion() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Line")
        descriptor.positions = MeshBuffer([Vector3(0, 1, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)])
        descriptor.indicies = [0, 1]
        descriptor.primitiveTopology = .lineList
        let lineMesh = Mesh.generate(from: [descriptor], renderDevice: device)
        let line = try #require(lineMesh.models.first?.parts.first)
        let lines = Array(repeating: line, count: 128)
        var source = Mesh3DRenderSource(
            entity: 64,
            drawPass: Model3DDrawPass(),
            mesh: Mesh(models: [Mesh.Model(name: "Lines", parts: lines)]),
            materials: [PBRMaterial()],
            transform: .identity,
            bounds: nil
        )
        source.instances = (0..<128).map { Mesh3DInstance(id: UInt64($0)) }
        var scene = PathTracing3DScene()
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.triangleCount == 0)
        #expect(scene.preparedPartVisitCount == 0)
        descriptor.primitiveTopology = .triangleList
        descriptor.indicies = [0, 1, 2]
        let triangleMesh = Mesh.generate(from: [descriptor], renderDevice: device)
        let triangle = try #require(triangleMesh.models.first?.parts.first)
        source.mesh = Mesh(models: [Mesh.Model(name: "Mixed geometry", parts: lines + [triangle])])
        try await scene.prepare([source], skinning: nil, device: device)
        #expect(scene.triangleCount == 128)
        #expect(scene.preparedPartVisitCount == 128)
        #expect(scene.preparedVertexCount == 384)
    }
}
