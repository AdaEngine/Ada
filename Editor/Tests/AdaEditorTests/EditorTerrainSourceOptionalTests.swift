@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor terrain optional residency", .serialized)
struct EditorTerrainSourceOptionalTests {
    @Test("Omitted nil radius retains full-set residency through codecs and scene reopening", arguments: [false, true])
    func optionalRadius(fullSet: Bool) throws {
        EditorComponentRegistry.registerBuiltIns()
        let source = Terrain3DSource(streamingRadius: fullSet ? nil : 12)
        let encoded = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(source))
        let name = String(reflecting: Terrain3DSource.self)
        for payload in [encoded, EditorTerrainSourcePayload.encode(source)] {
            #expect(try EditorTerrainSourcePayload.decode(payload).streamingRadius == source.streamingRadius)
            var model = EditorSceneModel.default(projectName: "Terrain")
            let id = model.addEntity(name: "Terrain", parentID: nil).id
            let index = try #require(model.entities.firstIndex { $0.id == id })
            model.entities[index].components[name] = payload
            let world = World(name: "Terrain optional")
            let loaded = EditorSceneFileLoader.load(content: try model.encodedYAML(), into: world, loadsPhysicsBodies: false)
            let entity = try #require(loaded.entitiesByEditorID[id].flatMap { world.getEntityByID($0) })
            #expect(entity.components[Terrain3DSource.self]?.streamingRadius == source.streamingRadius)
        }
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: name))
        let defaults = try #require(try descriptor.decode(descriptor.makeDefaultPayload()) as? Terrain3DSource)
        #expect(defaults.streamingRadius == 384, "New components still retain the engine's explicit camera-streaming default")
    }
}
