@_spi(Internal) @testable import AdaAssets
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func budgetSidecarPayloads(parts: Int) throws -> (Data, Data) {
        let positions: [Vector3] = [[0, 1, 0], [-1, -1, 0], [1, -1, 0]]
        let indices: [UInt32] = [0, 1, 2]
        let flat = try MeshletGeometry.scan(positions: positions, indices: indices)
        let node = MeshletLODNode(
            parent: nil,
            firstChild: 0,
            childCount: 0,
            firstCluster: 0,
            clusterCount: 1,
            minimum: [-1, -1, 0],
            maximum: [1, 1, 0],
            error: 0,
            firstSourceIndex: 0,
            sourceIndexCount: 3
        )
        let lod = try MeshletLODGeometry(positions: positions, sourceIndices: indices, geometry: flat, nodes: [node], roots: [0])
        let flatFile = MeshletSidecar(parts: (0..<parts).map { .init(meshIndex: $0, partIndex: 0, geometry: flat) })
        let lodFile = MeshletLODSidecar(parts: (0..<parts).map { .init(meshIndex: $0, partIndex: 0, geometry: lod) })
        return (try flatFile.encoded(), try lodFile.encoded())
    }

    private func sidecarRootFootprint(_ bytes: Data) throws -> ModelImportFootprint {
        let imported = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 1_048_576, maximumDecodedBytes: 1_048_576)) {
            try NativeGLTFLoader().load(data: bytes)
        }
        return try #require(imported.importFootprint)
    }

    @Test("Optional derived sidecars exceeding remaining encoded budget leave original geometry", arguments: ["meshlets", "meshletlod"])
    func terrainModelSidecarEncodedReadBudget(format: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let root = directory.appendingPathComponent("rock.gltf")
        let bytes = try terrainGLTFDocument(normals: 3)
        try bytes.write(to: root)
        let footprint = try sidecarRootFootprint(bytes)
        let (flat, lod) = try budgetSidecarPayloads(parts: 64)
        let sidecar = format == "meshlets" ? flat : lod
        try sidecar.write(to: root.appendingPathExtension(format))
        let tooSmall = footprint.encodedBytes + sidecar.count - 1
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: tooSmall, maximumDecodedBytes: 1_048_576)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        let part = try #require(model.meshes.first?.models.first?.parts.first)
        #expect(part.indexCount == 3)
        #expect(model.importWarnings.contains { $0.lowercased().contains("budget") })
        #expect(format == "meshlets" ? part.meshlets == nil : part.meshletLOD == nil)
        let valid = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: tooSmall + 1, maximumDecodedBytes: 1_048_576)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        let prepared = try #require(valid.meshes.first?.models.first?.parts.first)
        #expect(format == "meshlets" ? prepared.meshlets != nil : prepared.meshletLOD != nil)
    }

    @Test("Flat and LOD sidecars share the same remaining encoded import allowance")
    func terrainModelSidecarAggregateReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let root = directory.appendingPathComponent("rock.gltf")
        let bytes = try terrainGLTFDocument(normals: 3)
        try bytes.write(to: root)
        let footprint = try sidecarRootFootprint(bytes)
        let (flat, lod) = try budgetSidecarPayloads(parts: 16)
        try flat.write(to: root.appendingPathExtension("meshlets"))
        try lod.write(to: root.appendingPathExtension("meshletlod"))
        let total = footprint.encodedBytes + flat.count + lod.count
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: total - 1, maximumDecodedBytes: 1_048_576)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        let part = try #require(model.meshes.first?.models.first?.parts.first)
        #expect(part.meshlets != nil && part.meshletLOD == nil)
        #expect(model.importWarnings.contains { $0.lowercased().contains("budget") })
        let valid = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: total, maximumDecodedBytes: 1_048_576)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        #expect(valid.meshes.first?.models.first?.parts.first?.meshletLOD != nil)
    }

    @Test("Derived sidecar expansion consumes decoded allowance before parsing")
    func terrainModelSidecarDecodedReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let root = directory.appendingPathComponent("rock.gltf")
        let bytes = try terrainGLTFDocument(normals: 3)
        try bytes.write(to: root)
        let footprint = try sidecarRootFootprint(bytes)
        let (_, lod) = try budgetSidecarPayloads(parts: 64)
        try lod.write(to: root.appendingPathExtension("meshletlod"))
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: footprint.decodedBytes + lod.count)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        #expect(model.meshes.first?.models.first?.parts.first?.meshletLOD == nil)
        #expect(model.importWarnings.contains { $0.lowercased().contains("budget") })
    }

    @Test("Optional sidecars never displace mandatory model textures", arguments: [false, true])
    func terrainModelSidecarPreservesTexturedFallback(invalid: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        var document = try #require(JSONSerialization.jsonObject(with: terrainGLTFDocument(normals: 3)) as? [String: Any])
        let pixels = Data(repeating: 255, count: 32 * 32 * 4)
        let png = try Image(width: 32, height: 32, data: pixels, format: .rgba8).pngData()
        document["images"] = [["uri": "data:image/png;base64," + png.base64EncodedString()]]
        document["textures"] = [["source": 0]]
        document["materials"] = [["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]]]
        var meshes = try #require(document["meshes"] as? [[String: Any]])
        var primitives = try #require(meshes[0]["primitives"] as? [[String: Any]])
        primitives[0]["material"] = 0
        meshes[0]["primitives"] = primitives
        document["meshes"] = meshes
        let bytes = try JSONSerialization.data(withJSONObject: document)
        let root = directory.appendingPathComponent("rock.gltf")
        try bytes.write(to: root)
        let footprint = try sidecarRootFootprint(bytes)
        let (flat, _) = try budgetSidecarPayloads(parts: 64)
        let sidecar = invalid ? Data(repeating: 0, count: flat.count) : flat
        let limits = ModelImportLimits(maximumEncodedBytes: 65_536, maximumDecodedBytes: footprint.decodedBytes + flat.count * 16)
        let baseline = try await ModelImportContext.$limits.withValue(limits) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        #expect((baseline.materials.first as? PBRMaterial)?.baseColorTexture != nil)
        try sidecar.write(to: root.appendingPathExtension("meshlets"))
        await #expect(throws: Never.self) {
            let model = try await ModelImportContext.$limits.withValue(limits) {
                try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
            }
            #expect((model.materials.first as? PBRMaterial)?.baseColorTexture != nil)
            #expect(model.meshes.first?.models.first?.parts.first?.meshlets == nil)
            #expect(!model.importWarnings.isEmpty)
        }
    }

    @Test("Rejected sidecar parsing releases decoded reservation for the next optional resource")
    func terrainModelSidecarReclaimsRejectedExpansion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let root = directory.appendingPathComponent("rock.gltf")
        let bytes = try terrainGLTFDocument(normals: 3)
        try bytes.write(to: root)
        let footprint = try sidecarRootFootprint(bytes)
        let (_, lod) = try budgetSidecarPayloads(parts: 64)
        try Data(repeating: 0, count: 512).write(to: root.appendingPathExtension("meshlets"))
        try lod.write(to: root.appendingPathExtension("meshletlod"))
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: footprint.decodedBytes + lod.count * 16)) {
            try await AssetsManager.loadFresh(ModelAsset3D.self, at: root.path)
        }
        #expect(model.meshes.first?.models.first?.parts.first?.meshletLOD != nil)
        #expect(!model.importWarnings.isEmpty)
    }
}
