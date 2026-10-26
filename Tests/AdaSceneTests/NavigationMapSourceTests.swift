@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaNavigation
import AdaNavigationBaking
import AdaScene
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct NavigationMapSourceTests {
    private func fixture() async throws -> (URL, NavigationMeshData) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try await NavigationMeshBaker.bake(
            vertices: [[0, 0, 0], [0, 0, 10], [10, 0, 10], [10, 0, 0]], indices: [0, 1, 2, 0, 2, 3]
        )
        try data.encoded().write(to: root.appendingPathComponent("floor.navmesh"))
        return (root, data)
    }

    private func app(_ root: URL) async throws -> AppWorlds {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(AssetsPlugin(assetDirectory: root)).addPlugin(Navigation3DPlugin())
        try await app.build()
        return app
    }

    @Test func loadsRealAssetFailsCleanlyAndRecoversAfterReferenceChanges() async throws {
        let (root, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try await app(root)
        let entity = app.main.spawn { NavigationMap3DSource(source: "@res://floor.navmesh") }
        await app.withExecutionContext { await app.main.runScheduler(.preUpdate) }
        #expect(entity.components[NavigationMap3DSource.self]?.status == "ready", "\(entity.components[NavigationMap3DSource.self]?.errorMessage ?? "")")
        let map = try #require(app.main.getResource(NavigationMap3D.self))
        #expect(try await map.mesh.findPath(from: [1, 0, 1], to: [9, 0, 9]).status == .complete)
        entity.components[NavigationMap3DSource.self] = .init(source: "@res://missing.navmesh")
        await app.withExecutionContext { await app.main.runScheduler(.preUpdate) }
        #expect(entity.components[NavigationMap3DSource.self]?.errorCode == "assetLoadFailed")
        #expect(app.main.getResource(NavigationMap3D.self) == nil)
        entity.components[NavigationMap3DSource.self] = .init(source: "@res://floor.navmesh")
        await app.withExecutionContext { await app.main.runScheduler(.preUpdate) }
        #expect(app.main.getResource(NavigationMap3D.self)?.revision != map.revision)
        entity.components[NavigationMap3DSource.self] = nil
        await app.withExecutionContext { await app.main.runScheduler(.preUpdate) }
        #expect(app.main.getResource(NavigationMap3D.self) == nil)
    }

    @Test func duplicateSourcesPreserveExternalMapAndTransientStateIsNotSerialized() async throws {
        let (root, data) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try await app(root)
        let external = NavigationMap3D(mesh: try NavigationMesh(data: data))
        app.main.insertResource(external)
        let first = app.main.spawn { NavigationMap3DSource(source: "@res://floor.navmesh") }
        app.main.spawn { NavigationMap3DSource(source: "@res://floor.navmesh") }
        await app.withExecutionContext { await app.main.runScheduler(.preUpdate) }
        let value = try #require(first.components[NavigationMap3DSource.self])
        #expect(value.errorCode == "multipleSources")
        #expect(app.main.getResource(NavigationMap3D.self)?.revision == external.revision)
        let decoded = try JSONDecoder().decode(NavigationMap3DSource.self, from: JSONEncoder().encode(value))
        #expect(decoded.status == "idle" && decoded.errorCode.isEmpty && decoded.polygonCount == 0)
    }
}
