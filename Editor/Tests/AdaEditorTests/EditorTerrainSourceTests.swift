@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor terrain source", .serialized)
struct EditorTerrainSourceTests {
    @Test("Terrain Source is available in the Inspector and its defaults decode")
    func inspector() throws {
        EditorComponentRegistry.registerBuiltIns()
        let name = String(reflecting: Terrain3DSource.self)
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: name))
        #expect(descriptor.fields.contains { $0.key == "source" && $0.kind == .assetReference })
        #expect(descriptor.fields.contains { $0.key == "generatesCollision" && $0.kind == .bool })
        let source = try #require(try descriptor.decode(descriptor.makeDefaultPayload()) as? Terrain3DSource)
        #expect(source.source.isEmpty)
        #expect(source.generatesCollision)
    }

    @Test("Portable scene references reopen in edit and Play without leaking preview settings", arguments: [false, true])
    func reopen(play: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TerrainEditor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let directory = assets.appendingPathComponent("Terrain", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrainFile = directory.appendingPathComponent("world.aterrain")
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 3, size: 2))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -1, originZ: -1), at: terrainFile.path)
        let name = String(reflecting: Terrain3DSource.self)
        var model = EditorSceneModel.default(projectName: "Terrain")
        let id = model.addEntity(name: "Ground", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        let source = Terrain3DSource(source: "@res://Terrain/world.aterrain")
        model.entities[index].components[name] = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(source))
        let content = try model.encodedYAML()
        let world = World(name: "Editor terrain")
        let loaded = EditorSceneFileLoader.load(
            content: content,
            into: world,
            loadsScriptableObjects: play,
            loadsPhysicsBodies: play,
            sourceURL: assets.appendingPathComponent("Main.ascn"),
            resourceRootURL: assets
        )
        #expect(loaded.warnings.isEmpty, Comment(rawValue: loaded.warnings.joined(separator: "\n")))
        let entity = try #require(loaded.entitiesByEditorID[id].flatMap { world.getEntityByID($0) })
        let component = try #require(entity.components[Terrain3DSource.self])
        #expect(component.source == terrainFile.standardizedFileURL.path)
        #expect(component.generatesCollision == play)
        if !play { #expect(component.queries != nil) }
        let reopened = try EditorSceneModel.decode(from: content)
        let payload = try #require(reopened.entities.first { $0.id == id }?.components[name])
        #expect(payload["source"] == .string("@res://Terrain/world.aterrain"))
        #expect(payload["generatesCollision"] == .bool(true))
    }

    @Test("Terrain paths cannot leave project Assets, use other formats or resolve missing files")
    func resourceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TerrainBoundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("outside.aterrain"))
        let name = String(reflecting: Terrain3DSource.self)
        for reference in ["@res://../outside.aterrain", "../outside.aterrain", "@res://missing.aterrain", "@res://wrong.png"] {
            #expect(throws: (any Error).self) {
                try EditorSceneFileLoader.resolvedComponentPayload(
                    typeName: name,
                    payload: ["source": .string(reference)],
                    sourceURL: assets.appendingPathComponent("Main.ascn"),
                    resourceRootURL: assets
                )
            }
        }
    }
}
