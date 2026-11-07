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

@MainActor @Suite("Mesh Terrain preview supersession", .serialized)
struct MeshTerrainSupersessionTests {
    @Test("An in-flight preview cannot replace the accepted surface once new input supersedes its ticket",
          .enabled(if: TriangleMeshBoolean.isAvailable))
    func invalidatedPreviewKeepsAcceptedSurface() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshSupersession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let root = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))],
            modifiers: [.init(sourceID: 1, operation: .union, surface: root)])
        let initial = try await MeshTerrainDocumentAsset(document: document).compiling()
        let file = directory.appendingPathComponent("world.aterrain")
        try initial.encodedData().write(to: directory.appendingPathComponent("surface.atmesh"))
        try TerrainManifestAsset(meshDocumentFileName: "surface.atmesh").encodedData().write(to: file)
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") { Transform(); Terrain3DSource(source: file.path, generatesCollision: false, queries: .init()) }
        let source = app.main.spawn("Root") { Transform() }
        try await settle(app) { owner.components[Terrain3DSourceStatus.self]?.isReady == true }
        let prior = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.revision)
        let key = try initial.authoringKey()
        let ticket = MeshTerrainEditTicket()
        let first = request(document, ownerKey: key, source: source.id, x: -3, ticket: ticket)
        owner.components[MeshTerrain3DEdit.self] = first
        try await settle(app) { owner.components[Terrain3DSourceStatus.self]?.isPreparing == true }
        // This models a pointer event while its replacement has not yet
        // acquired world access; the old ECS edit component is still current.
        try #require(owner.components[MeshTerrain3DEdit.self]?.id == first.id)
        ticket.supersede()
        try await settle(app) {
            guard let status = owner.components[MeshTerrain3DEditStatus.self] else { return false }
            return status.id == first.id && status.phase != .pending
        }
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .cancelled)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.revision == prior)
        #expect(source.components[Transform.self]?.position.x == 0)
        let accepted = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
        let latest = request(document, ownerKey: try accepted.authoringKey(), source: source.id, x: 3, ticket: .init())
        owner.components[MeshTerrain3DEdit.self] = latest
        try await settle(app) {
            guard let status = owner.components[MeshTerrain3DEditStatus.self] else { return false }
            return status.id == latest.id && status.phase != .pending
        }
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.phase == .applied)
        #expect(source.components[Transform.self]?.position.x == 3)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 2)
    }

    private func request(
        _ document: MeshTerrainDocument, ownerKey: Data, source: Entity.ID, x: Float, ticket: MeshTerrainEditTicket
    ) -> MeshTerrain3DEdit {
        var moved = document
        moved.modifiers[0].transform = .init(translation: [x, 0, 0])
        return .init(expectedInputKey: ownerKey, candidate: .init(document: moved),
            sourceTransforms: [.init(entity: source, pose: .init(position: [x, 0, 0]))], ticket: ticket)
    }

    private func settle(_ app: AppWorlds, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !done(), ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(done())
    }
}
