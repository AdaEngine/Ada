@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
struct EditorDecalAuthoringTests {
    @Test func savedSceneKeepsAnIndependentReceiverLocalProjector() throws {
        var scene = EditorSceneModel.default(projectName: "Decals")
        let owner = scene.addEntity(name: "Car", parentID: nil)
        let second = scene.addEntity(name: "Other car", parentID: nil)
        let viewport = EditorSceneViewportModel()
        viewport.sceneModel = scene
        viewport.selectedEditorID = owner.id
        let entry = Decal3DSource.Entry(
            node: .init(source: "@res://Cars/Car.glb", index: 4, name: "Body"),
            localFrame: Transform3D(translation: [0.25, 0.5, -0.75]),
            size: [0.35, 0.25, 0.15],
            rotationDegrees: 45,
            images: Decal3DImages(color: "@res://Images/Sticker.png", priority: 2)
        )
        let data = try JSONEncoder().encode(Decal3DSource(entries: [entry]))
        let payload = try JSONDecoder().decode(EditorComponentPayload.self, from: data)
        let ownerIndex = try #require(scene.entities.firstIndex { $0.id == owner.id })
        scene.entities[ownerIndex].components[EditorDecalEditing.componentType] = payload
        let reopened = try EditorSceneModel.decode(from: try scene.encodedYAML())
        viewport.sceneModel = reopened
        #expect(viewport.decalEditing.entries == [entry])
        viewport.selectedEditorID = second.id
        #expect(viewport.decalEditing.entries.isEmpty)
    }
}
