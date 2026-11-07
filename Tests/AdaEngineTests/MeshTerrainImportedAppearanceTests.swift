@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@MainActor @Suite("Mesh Terrain imported appearance", .serialized)
struct MeshTerrainImportedAppearanceTests {
    @Test("Joined imported bark preserves PBR textures, source UV1 and vertex colors on compiled reload",
          .enabled(if: TriangleMeshBoolean.isAvailable), arguments: [false, true])
    func joinedGLBBarkKeepsMapsAndVertexChannels(usesHostedModelPath: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeshGLBBark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixtureGLB().write(to: directory.appendingPathComponent("tree.glb"))
        let ground = try TriangleSurface.ground(size: [12, 8], cells: 6)
        let initial = try await MeshTerrainDocumentAsset(document: .init(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))])).compiling()
        try initial.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
        try TerrainManifestAsset(meshDocumentFileName: "ground.atmesh").encodedData().write(to: directory.appendingPathComponent("ground.aterrain"))
        let app = AppWorlds(main: World())
        let directories = try ProjectDirectories(source: directory, assetsDirectory: directory, storageIdentifier: "mesh-bark-\(UUID())")
        try await AppWorldsExecutionContext.$currentID.withValue(app.executionID) {
            await AssetsManager.setProjectDirectories(directories)
            app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
            try await app.build()
            let ownerID = UUID()
            let owner = app.main.spawn("Ground") {
                Transform(); Terrain3DSource(source: "@res://ground.aterrain", generatesCollision: false); MeshTerrain3DIdentity(id: ownerID)
            }
            let portableModel = "@res://tree.glb"
            let resolvedModel = directory.appendingPathComponent("tree.glb").path
            let tree = app.main.spawn("Textured tree") {
                Transform(); MeshTerrain3DIdentity(); Model3DSource(source: usesHostedModelPath ? resolvedModel : portableModel)
            }
            if usesHostedModelPath {
                tree.components[MeshTerrain3DSourceModelResource.self] = .init(resolvedPath: resolvedModel, resourcePath: portableModel)
            }
            try await settle(app) {
                owner.components[Terrain3DSourceStatus.self]?.isReady == true && tree.components[Model3DSourceState.self]?.rootEntityID != nil
            }
            tree.components[MeshTerrain3DBinding.self] = .init(target: ownerID, sourceID: 17)
            try await settle(app) {
                let phase = tree.components[MeshTerrain3DBindingStatus.self]?.phase
                return phase == .applied || phase == .failed
            }
            try #require(tree.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
            let accepted = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
            try accepted.encodedData().write(to: directory.appendingPathComponent("joined.atmesh"))
            try TerrainManifestAsset(meshDocumentFileName: "joined.atmesh").encodedData().write(to: directory.appendingPathComponent("joined.aterrain"))
            app.main.removeEntity(tree.id, recursively: true)
            let reopened = app.main.spawn("Compiled only") {
                Transform(position: [24, 0, 0]); Terrain3DSource(source: "@res://joined.aterrain", generatesCollision: false)
            }
            try await settle(app) { reopened.components[Terrain3DSourceStatus.self]?.isReady == true }
            let draw = try #require(reopened.children.compactMap { $0.components[Mesh3DComponent.self] }.first)
            let bark = try #require(draw.materials.compactMap { $0 as? PBRMaterial }.first { $0.baseColorFactor.x == 0.42 })
            #expect(bark.baseColorTexture?.width == 2)
            #expect(bark.normalTexture?.height == 2)
            #expect(bark.metallicRoughnessTexture?.width == 2)
            #expect(bark.textureCoordinates[0] == 1 && bark.textureCoordinates[1] == 1)
            let part = try #require(draw.mesh.models.flatMap(\.parts).first { draw.materials[$0.materialIndex] === bark })
            let uv = part.meshDescriptor[MeshDescriptor.textureCoordinates1]?.elements
            #expect(uv?.count == part.meshDescriptor.positions.elements.count)
            #expect(uv?.allSatisfy { abs($0.x - 0.65) < 0.001 } == true)
            let colors = part.meshDescriptor.colors?.elements
            #expect(colors?.count == part.meshDescriptor.positions.elements.count)
            #expect(colors?.allSatisfy { abs($0.green - 0.42) < 0.001 } == true)
        }
    }

    private func settle(_ app: AppWorlds, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !done(), ContinuousClock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(done())
    }

    private func fixtureGLB() throws -> Data {
        let box = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        var bin = Data(), views: [[String: Int]] = [], accessors: [[String: Any]] = []
        func append32(_ value: UInt32, to data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func view(_ data: Data) -> Int {
            while !bin.count.isMultiple(of: 4) { bin.append(0) }
            views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": data.count])
            bin.append(data)
            return views.count - 1
        }
        func accessor(_ words: [UInt32], _ count: Int, _ type: String, _ component: Int) -> Int {
            var bytes = Data()
            for word in words { append32(word, to: &bytes) }
            accessors.append(["bufferView": view(bytes), "componentType": component, "count": count, "type": type])
            return accessors.count - 1
        }
        let count = box.positions.count
        let positions = accessor(box.positions.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }, count, "VEC3", 5126)
        let normals = accessor(Array(repeating: [Float(0).bitPattern, Float(1).bitPattern, Float(0).bitPattern], count: count).flatMap { $0 }, count, "VEC3", 5126)
        let firstUV = accessor(Array(repeating: [Float(0.13).bitPattern, Float(0.23).bitPattern], count: count).flatMap { $0 }, count, "VEC2", 5126)
        let secondUV = accessor(Array(repeating: [Float(0.65).bitPattern, Float(0.45).bitPattern], count: count).flatMap { $0 }, count, "VEC2", 5126)
        let color = accessor(Array(repeating: [Float(0.8).bitPattern, Float(0.42).bitPattern, Float(0.3).bitPattern, Float(1).bitPattern],
            count: count).flatMap { $0 }, count, "VEC4", 5126)
        let indices = accessor(box.indices, box.indices.count, "SCALAR", 5125)
        let image = view(try Image(width: 2, height: 2, color: .brown).pngData())
        let mapped = ["index": 0, "texCoord": 1]
        let root: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": positions, "NORMAL": normals, "TEXCOORD_0": firstUV,
                "TEXCOORD_1": secondUV, "COLOR_0": color], "indices": indices, "material": 0]]]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": [0.42, 0.13, 0.06, 1], "baseColorTexture": mapped,
                "metallicRoughnessTexture": mapped], "normalTexture": mapped]],
            "buffers": [["byteLength": bin.count]], "bufferViews": views, "accessors": accessors,
            "images": [["bufferView": image, "mimeType": "image/png"]], "textures": [["source": 0]]
        ]
        var json = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        while !json.count.isMultiple(of: 4) { json.append(32) }
        while !bin.count.isMultiple(of: 4) { bin.append(0) }
        var glb = Data("glTF".utf8)
        append32(2, to: &glb)
        append32(UInt32(28 + json.count + bin.count), to: &glb)
        append32(UInt32(json.count), to: &glb)
        glb.append(contentsOf: "JSON".utf8); glb.append(json)
        append32(UInt32(bin.count), to: &glb)
        glb.append(contentsOf: [66, 73, 78, 0]); glb.append(bin)
        return glb
    }
}
