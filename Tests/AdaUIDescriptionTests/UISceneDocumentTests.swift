import AdaUIDescription
import Testing

struct UISceneDocumentTests {
    @Test func yamlRoundTripPreservesOrderedRepeatedModifiersAndBindings() throws {
        let document = UISceneDocument(root: .init(id: "title", type: "Text", arguments: ["text": .init(binding: "player.name")], modifiers: [
            .init(type: "padding", arguments: ["value": .init(value: .number(8))]),
            .init(type: "background", arguments: ["color": .init(value: .string("#ff0000"))]),
            .init(type: "padding", arguments: ["value": .init(value: .number(16))])
        ]))
        let restored = try UISceneDocument.decode(document.encodedYAML())
        #expect(restored == document)
        #expect(restored.root.modifiers.map(\.type) == ["padding", "background", "padding"])
    }

    @Test func duplicateNodeIDsAreRejectedAcrossModifierContent() {
        let document = UISceneDocument(root: .init(id: "same", type: "Text", modifiers: [.init(type: "overlay", children: [.init(id: "same", type: "Text")])]))
        #expect(throws: UIDiagnostic.self) { try document.validate() }
    }

    @Test func formatAndVersionAreValidated() {
        var document = UISceneDocument()
        document.schemaVersion = 2
        #expect(throws: UIDiagnostic.self) { try document.validate() }
        document.schemaVersion = 1
        document.format = "ada.scene"
        #expect(throws: UIDiagnostic.self) { try document.validate() }
    }

    @Test func ambiguousArgumentIsRejected() {
        var argument = UIArgument(value: .string("literal"))
        argument.binding = "name"
        let document = UISceneDocument(root: .init(type: "Text", arguments: ["text": argument]))
        #expect(throws: UIDiagnostic.self) { try document.validate() }
    }

    @Test func explicitNullAndMinimalYAMLRemainDistinctFromMissingValues() throws {
        let document = try UISceneDocument.decode("""
        format: ada.ui
        schemaVersion: 1
        inputs:
          - name: optionalValue
            type: any
            defaultValue: null
        root:
          id: root
          type: Text
          arguments:
            text: {value: null}
        """)
        #expect(document.inputs[0].defaultValue == .null)
        #expect(document.root.arguments["text"]?.value == .null)
        #expect(try UISceneDocument.decode(document.encodedYAML()) == document)
    }

    @Test func nestedValuesKeepTypes() throws {
        let document = UISceneDocument(inputs: [.init("items", type: .array, defaultValue: .array([.object(["id": .string("a"), "count": .number(3), "visible": .bool(true)])]))])
        let restored = try UISceneDocument.decode(document.encodedYAML())
        #expect(restored.inputs == document.inputs)
    }
}
