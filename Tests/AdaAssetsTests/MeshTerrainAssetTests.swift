import AdaAssets
import AdaGeometry
import Foundation
import Math
import Testing

@Suite struct MeshTerrainAssetTests {
    #if !WASM
        @Test("Heightfield saves leave an existing Mesh Terrain manifest and its compiled resource intact", arguments: [true, false])
        func heightfieldSaveCannotReplaceMeshTerrain(useCurrentManifest: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshTerrainSave-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let surface = try TriangleSurface.ground(size: [8, 8], cells: 4)
            let asset = try await MeshTerrainDocumentAsset(document: .init(sections: [
                .init(surface: surface, closure: .ground(bottomHeight: -4))
            ])).compiling()
            let resource = directory.appendingPathComponent("ground.atmesh")
            let resourceBytes = try asset.encodedData()
            try resourceBytes.write(to: resource)
            let destination = directory.appendingPathComponent("ground.aterrain")
            let manifest = TerrainManifestAsset(meshDocumentFileName: "ground.atmesh")
            let manifestBytes = try manifest.encodedData()
            try manifestBytes.write(to: destination)
            let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)],
                                            pages: [.init(x: 0, z: 0, samples: Array(repeating: 2, count: 4_096))])
            await #expect(throws: TerrainSaveError.self) {
                try await AssetsManager.saveTerrainRegions([region], manifest: useCurrentManifest ? manifest : .init(), at: destination.path)
            }
            #expect(try Data(contentsOf: destination) == manifestBytes)
            #expect(try Data(contentsOf: resource) == resourceBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["ground.aterrain", "ground.atmesh"])
        }
    #endif

    @Test func realResourceRoundTripRejectsStaleCompiledGeometry() async throws {
        let ground = try TriangleSurface.ground(size: [8, 8], cells: 4)
        let base = MeshTerrainBaseSection(surface: ground, closure: .ground(bottomHeight: -4))
        let source = MeshTerrainDocumentAsset(document: .init(sections: [base]))
        let built = try await source.compiling()
        let product = try #require(built.compiled)
        #expect(product.patches.count == 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMeshTerrain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ground.atmesh")
        try built.encodedData().write(to: file)
        let loaded = try await AssetsManager.loadFresh(MeshTerrainDocumentAsset.self, at: file.path)
        #expect(try loaded.acceptedCompiledProduct() == product)
        var moved = loaded.document
        moved.sections[0].surface.positions[0].y = 2
        let stale = MeshTerrainDocumentAsset(document: moved, compiled: product)
        #expect(throws: TriangleGeometryError.invalidInput) { try stale.acceptedCompiledProduct() }
        let manifest = TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "ground.atmesh")
        #expect(try TerrainManifestAsset(data: manifest.encodedData()).meshDocumentFileName == "ground.atmesh")
        #expect(throws: (any Error).self) { try TerrainManifestAsset(heightRegions: [], meshDocumentFileName: "../ground.atmesh").encodedData() }
    }
}
