@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor @Suite("Mesh Terrain retained paint", .serialized)
struct MeshTerrainPaintTests {
    private enum Frame: Codable { case base; case source(UUID) }
    private enum Operation: Codable { case paint(layer: UInt16); case erase }
    private struct Anchor: Codable {
        let frame: Frame
        let section: UUID
        let faceID: UInt32
        let point: Vector3
        let normal: Vector3
    }
    private struct Stamp: Codable {
        var id = UUID()
        let anchor: Anchor
        let radius: Float
        var strength: Float = 1
        let operation: Operation
    }
    private struct PaintDocument: Encodable {
        let version: Int
        let id: UUID
        let sections: [MeshTerrainBaseSection]
        let modifiers: [MeshTerrainModifier]
        let paint: [Stamp]
    }

    @Test(.enabled(if: TriangleMeshBoolean.isAvailable))
    func materialPaintFollowsItsOwnerAndEraseRestoresProceduralMaterial() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshPaint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = MeshTerrainBaseSection(surface: try .ground(size: [16, 12], cells: 16), closure: .ground(bottomHeight: -4))
        let rock = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        var source = MeshTerrainModifier(sourceID: 3, operation: .union, surface: rock, materialLayer: 21, contactWidth: 1.5)
        let baseline = try await MeshTerrainDocumentAsset(document: .init(sections: [base], modifiers: [source])).compiling()
        let originalPatch = try #require(baseline.compiled?.patches.first?.surface)
        let query = try TriangleSurfaceIndex(positions: originalPatch.positions, indices: originalPatch.indices)
        let ground = try #require(try query.raycast(.init(origin: [-4, 5, 0], direction: [0, -1, 0])))
        let top = try #require(try query.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0])))
        let groundAnchor = Anchor(frame: .base, section: base.id, faceID: originalPatch.faceIDs[ground.triangleIndex], point: ground.position, normal: ground.normal)
        let sourceAnchor = Anchor(frame: .source(source.id), section: base.id, faceID: originalPatch.faceIDs[top.triangleIndex], point: top.position, normal: top.normal)
        let strokes = [Stamp(anchor: groundAnchor, radius: 1.75, operation: .paint(layer: 30)),
                       Stamp(anchor: sourceAnchor, radius: 2.5, operation: .paint(layer: 30))]
        let palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "Ground"), .init(id: 21, name: "Rock"), .init(id: 30, name: "Paint")], fallbackLayerID: 7)
        let manifest = directory.appendingPathComponent("world.aterrain")
        let compiledFile = directory.appendingPathComponent("world.atmesh")
        try TerrainManifestAsset(materials: palette, meshDocumentFileName: "world.atmesh").encodedData().write(to: manifest)

        func compile(_ strokes: [Stamp]) async throws -> MeshTerrainDocumentAsset {
            let authored = PaintDocument(version: MeshTerrainDocument.formatVersion, id: baseline.document.id, sections: [base], modifiers: [source], paint: strokes)
            let document = try JSONDecoder().decode(MeshTerrainDocument.self, from: JSONEncoder().encode(authored))
            return try await MeshTerrainDocumentAsset(document: document).compiling()
        }
        source.transform = .init(translation: [3, 0, 0])
        let unpainted = try await compile([])
        let painted = try await compile(strokes)
        try painted.encodedData().write(to: compiledFile)
        let reloaded = try MeshTerrainDocumentAsset(data: Data(contentsOf: compiledFile))
        #expect(try reloaded.authoringKey() != unpainted.authoringKey())
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Painted terrain") { Transform(); Terrain3DSource(source: manifest.path, generatesCollision: false, queries: .init()) }
        try await settle(app) { owner.components[Terrain3DSourceStatus.self]?.isReady == true }
        let originalQueries = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        let before = try paintAmounts(owner)
        #expect(before.fixedGround > 0)
        #expect(before.movedSource > 0)
        #expect(before.oldSourceFootprint == 0)
        #expect(before.otherSourceSide == 0)

        let erased = try await compile(strokes + [.init(anchor: sourceAnchor, radius: 2.5, operation: .erase)])
        let edit = MeshTerrain3DEdit(expectedInputKey: try reloaded.authoringKey(), candidate: erased)
        owner.components[MeshTerrain3DEdit.self] = edit
        try await settle(app) { owner.components[MeshTerrain3DEditStatus.self]?.id == edit.id && owner.components[MeshTerrain3DEditStatus.self]?.phase != .pending }
        try #require(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        let after = try paintAmounts(owner)
        #expect(after.fixedGround == before.fixedGround)
        #expect(after.movedSource == 0)
        #expect(after.restoredRock > 0)
        let queries = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(queries.tileGeneration(at: .init(x: 0, z: 0)) == originalQueries.tileGeneration(at: .init(x: 0, z: 0)))
    }

    private func settle(_ app: AppWorlds, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if ready() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(ready())
    }

    private struct PaintAmounts {
        var fixedGround = 0
        var movedSource = 0
        var oldSourceFootprint = 0
        var otherSourceSide = 0
        var restoredRock = 0
    }

    private func paintAmounts(_ owner: Entity) throws -> PaintAmounts {
        let terrain = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        let patch = try #require(terrain.asset.compiled?.patches.first?.surface)
        let mesh = try #require(owner.children.compactMap { $0.components[Mesh3DComponent.self] }.first)
        let material = try #require(mesh.materials.first as? PBRMaterial)
        let bindings = try #require(material.terrainBindings)
        let engine = try #require(unsafe RenderEngine.shared)
        let ids = try #require(engine.renderDevice.getImage(from: bindings.layerIDs))
        let weights = try #require(engine.renderDevice.getImage(from: bindings.weights))
        let columns = max(1, Int(ceil(Double(patch.indices.count / 3).squareRoot())))
        var amounts = PaintAmounts()
        for face in 0..<patch.indices.count / 3 {
            let x = (face % columns) * 2, y = (face / columns) * 2
            let a = patch.positions[Int(patch.indices[face * 3])]
            let b = patch.positions[Int(patch.indices[face * 3 + 1])]
            let c = patch.positions[Int(patch.indices[face * 3 + 2])]
            let normal = (b - a).cross(c - a).normalized
            for corner in 0..<3 {
                let texel = ((y + (corner == 2 ? 1 : 0)) * weights.width + x + (corner == 1 ? 1 : 0)) * 4
                let position = patch.positions[Int(patch.indices[face * 3 + corner])]
                let paint = (0..<4).reduce(0) { $0 + (ids.data[texel + $1] == 2 ? Int(weights.data[texel + $1]) : 0) }
                if patch.faceSources[face] == 0 {
                    if abs(position.x + 4) <= 1.5, abs(position.z) <= 1.5 { amounts.fixedGround += paint }
                    if abs(position.x) <= 1, abs(position.z) <= 1 { amounts.oldSourceFootprint += paint }
                } else if patch.faceSources[face] == 3 {
                    if normal.y > 0.9, position.x >= 2 {
                        amounts.movedSource += paint
                        if ids.data[texel] == 1, weights.data[texel] == 255 { amounts.restoredRock += 1 }
                    } else {
                        amounts.otherSourceSide += paint
                    }
                }
            }
        }
        return amounts
    }
}
