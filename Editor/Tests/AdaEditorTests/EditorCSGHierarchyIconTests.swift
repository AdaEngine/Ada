import Testing

@testable import AdaEditor

@Suite("CSG hierarchy icons")
struct EditorCSGHierarchyIconTests {
    @Test("The hierarchy gives the group and each CSG shape a renderable icon")
    func displaysCSGShapeIcons() throws {
        var model = EditorSceneModel.default(projectName: "CSG hierarchy")
        let group = model.addEntity(template: .csgGroup, parentID: nil)
        let cube = try #require(model.csgBoxes(in: group.id).first)
        let addedSphere = model.addCSGBox(to: group.id, shape: .sphere)
        let addedCylinder = model.addCSGBox(to: group.id, shape: .cylinder)
        let sphere = try #require(addedSphere)
        let cylinder = try #require(addedCylinder)
        let rows = EditorSceneHierarchyModel.visibleItems(for: model, includesResources: false)
        let symbols = try [group.id, cube.id, sphere.id, cylinder.id].map { id in
            let item = try #require(rows.first { $0.id == id })
            return EditorSceneHierarchyIcon.symbol(for: item)
        }
        #expect(Set(symbols).count == 4, "Each CSG kind has a distinct icon")
        #expect(symbols.allSatisfy { $0 != EditorSceneHierarchyIcon.entity })
        let glyphs = symbols.compactMap { $0.unicodeScalars.first?.value }
        #expect(Set(glyphs).isSubset(of: Set(AdaEditorMaterialSymbolFont.codepoints)))
    }
}
