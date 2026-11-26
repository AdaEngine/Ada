import Testing

@testable import AdaEditor

@Suite
struct EditorSceneEntityEncodingTests {
    @Test
    func generatedJSONRemainsJSONThroughSelectionAndEntityEdits() throws {
        let content = """
        {
          "format": "ada.scene", "schemaVersion": 1,
          "scene": {"id": "fixture", "name": "Generated"},
          "entities": [{"id": "object", "name": "Object", "enabled": true, "components": {}}]
        }
        """
        let original = try EditorSceneModel.decode(from: content)
        var selected = original
        selected.selectEntity("object")
        let selectedContent = try selected.encodedYAML(updatingEditorStateIn: content)
        #expect(selectedContent.first == "{")
        #expect(EditorSceneModel.onlyEditorStateChanged(from: content, to: selectedContent))

        var edited = selected
        let hidObject = edited.setEntityEnabled("object", isEnabled: false)
        #expect(hidObject)
        let editedContent = try edited.encodedYAML(updatingEntitiesFrom: selected, in: selectedContent)
        #expect(editedContent.first == "{")
        #expect(!EditorSceneModel.onlyEditorStateChanged(from: selectedContent, to: editedContent))
        #expect(try EditorSceneModel.decode(from: editedContent) == edited)
    }

    @Test
    func flowYAMLCanKeepNonFiniteComponentValues() throws {
        let source = """
        {"format": ada.scene, "schemaVersion": 1, "scene": {id: example, name: Example},
         "entities": [{id: object, name: Object, enabled: true, components: {Example.Payload: {value: .inf}}}]}
        """
        let original = try EditorSceneModel.decode(from: source)
        var edited = original
        let hidObject = edited.setEntityEnabled("object", isEnabled: false)
        #expect(hidObject)
        let output = try edited.encodedYAML(updatingEntitiesFrom: original, in: source)
        #expect(output.first != "{")
        #expect(try EditorSceneModel.decode(from: output) == edited)
    }

    @Test
    func largeSceneWithEditorStateBeforeEntitiesRoundTrips() throws {
        let payload = String(repeating: "x", count: 1_100_000)
        let source = """
        format: ada.scene
        schemaVersion: 1
        scene:
          id: fixture-scene
          name: Fixture scene
        editor:
          selectedEntity: retained-object
          expandedEntities: []
        entities:
        - id: retained-object
          name: Retained object
          enabled: true
          components:
            Example.Payload:
              raw: "\(payload)"
        """
        let original = try EditorSceneModel.decode(from: source)
        var edited = original
        edited.selectEntity(nil)
        let output = try edited.encodedYAML(updatingEntitiesFrom: original, in: source)

        #expect(output.split(separator: "\n").filter { $0 == "editor:" }.count == 1)
        #expect(try EditorSceneModel.decode(from: output) == edited)
    }

    @Test
    func largeSceneEditsRetainUntouchedYAMLBlocks() throws {
        let payload = String(repeating: "x", count: 1_100_000)
        let source = """
        format: ada.scene
        schemaVersion: 1
        scene:
          id: fixture-scene
          name: Fixture scene
        entities:
        - id: original-parent
          name: Original parent
          enabled: true
          components: {}
        - id: edited-object
          name: Edited object
          enabled: true
          parent: original-parent
          components: {}
        - id: retained-object
          name: Retained object
          enabled: true
          components:
            Example.Payload:
              raw: "\(payload)" # original formatting
        editor:
          selectedEntity: edited-object
          expandedEntities: [original-parent]
        """
        let original = try EditorSceneModel.decode(from: source)
        var edited = original
        let target = edited.addEntity(name: "New parent", parentID: nil)
        let hidObject = edited.setEntityEnabled("edited-object", isEnabled: false)
        let movedObject = edited.reparentEntity("edited-object", to: target.id)
        #expect(hidObject)
        #expect(movedObject)
        let output = try edited.encodedYAML(updatingEntitiesFrom: original, in: source)

        #expect(output.contains("# original formatting"))
        #expect(try EditorSceneModel.decode(from: output) == edited)
    }
}
