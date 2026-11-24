@_spi(Internal) import AdaEngine
import Testing

@testable import AdaEditor

@Suite("Mixed CSG shapes and UVs", .enabled(if: CSGGroupSource.isAvailable))
struct EditorCSGShapesUVTests {
    @Test("Authored shapes survive a Boolean cut with portable texture coordinates")
    func exportsShapedCut() async throws {
        var model = EditorSceneModel.default(projectName: "CSG Shapes")
        let group = model.addEntity(template: .csgGroup, parentID: nil)
        let first = model.csgBoxes(in: group.id).first
        let boxID = try #require(first?.id)
        let sphere = try #require(model.entities.firstIndex { $0.id == boxID })
        model.entities[sphere].components[EditorCSGScene.boxType]?["shape"] = .string("sphere")
        let cut = model.addCSGBox(to: group.id)
        let box = try #require(cut)
        let cylinder = try #require(model.entities.firstIndex { $0.id == box.id })
        model.entities[cylinder].components[EditorCSGScene.boxType]?["shape"] = .string("cylinder")
        model.entities[cylinder].components[EditorBuiltInComponentType.transform]?["scale"] = .array([.double(0.4), .int(2), .double(0.4)])
        model.setCSGOperation(.subtract, for: box.id)

        let saved = try EditorSceneModel.decode(from: model.encodedYAML())
        let savedGroup = try #require(saved.entities.first { $0.id == group.id })
        let result = try await saved.csgSource(savedGroup).evaluate()
        let solid = try ScalarMeshSolid(positions: result.surface.positions, indices: result.surface.indices)
        #expect(try solid.value(at: [0.4, 0.4, 0.4]) > 0, "A sphere leaves the old box corner outside")
        #expect(try solid.value(at: [0, 0, 0]) > 0)
        #expect(try solid.value(at: [0.32, 0, 0]) < 0)
        let asset = try NativeGLTFLoader().load(data: result.modelData())
        let uv = asset.meshes.first?.primitives.first?.attributes[.texCoord(0)]?.vector2Values() ?? []
        #expect(uv.contains { $0.x != 0 && $0.y != 0 }, "The portable mesh carries the automatic UV layout")
    }
}
