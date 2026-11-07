@testable import AdaEditor
@_spi(AdaEngine) import AdaEngine
import Testing

@MainActor
@Suite("Terrain authored selection")
struct EditorTerrainPickingTests {
    @Test("Terrain remains selectable away from its origin when generated meshes belong to children")
    func selectsAuthoredTerrain() {
        let world = World()
        let owner = world.spawn("Terrain") {
            Transform(); Terrain3D()
        }
        let picked = EditorMeshPicking.pick(
            ray: Ray(origin: [15, 10, 0], direction: [0, -1, 0]),
            world: world,
            authoredEntities: ["ground": owner.id],
            editorIDs: [owner.id: "ground"],
            cameraID: nil
        )
        #expect(picked == "ground")
        owner.components[Visibility.self] = .hidden
        #expect(
            EditorMeshPicking.pick(
                ray: Ray(origin: [15, 10, 0], direction: [0, -1, 0]),
                world: world,
                authoredEntities: ["ground": owner.id],
                editorIDs: [owner.id: "ground"],
                cameraID: nil
            ) == nil
        )
    }
}
