import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("CSG authoring with the Studio agent")
struct EditorCSGAgentSkillTests {
    @Test("The Studio agent can discover and read the offline CSG skill")
    func discoversBundledSkill() throws {
        let catalog = try EditorAgentKnowledge.query(name: "editor.skills.list", arguments: ["query": "CSG"])
        let skills = try #require(catalog["skills"] as? [[String: String]])
        let found = skills.contains { $0["id"] == "ada-csg" }
        #expect(found, "CSG skill is available in the offline catalog")
        guard found else {
            return
        }
        let skill = try EditorAgentKnowledge.query(name: "editor.skills.read", arguments: ["id": "ada-csg"])
        let instructions = try #require(skill["content"] as? String)
        #expect(instructions.contains("editor.scene.apply"))
        #expect(instructions.contains("AdaStudio.CSGBox"))
    }

    @Test("The scene tool can apply the CSG skill's ordered component edits")
    func editsCSGGroup() throws {
        let tool = EditorAgentSceneToolService(projectURL: FileManager.default.temporaryDirectory)
        let model = EditorSceneModel.default(projectName: "Rooms")
        let group = EditorCSGScene.groupType
        let block = EditorCSGScene.boxType
        let operations: [EditorAgentSceneOperation] = [
            .createEntity(id: "level", name: "Level", parentID: nil, components: [group: ["version": .int(1)]]),
            .createEntity(id: "wall", name: "Wall", parentID: "level", components: [block: ["operation": .string("union")]]),
            .createEntity(id: "cut", name: "Round opening", parentID: "level", components: [
                block: ["operation": .string("subtract"), "shape": .string("cylinder")],
                EditorBuiltInComponentType.transform: [
                    "position": .array([.int(0), .int(0), .int(0)]),
                    "rotation": .array([.int(0), .int(0), .int(0), .int(1)]),
                    "scale": .array([.double(0.5), .int(2), .double(0.5)]),
                ],
            ]),
            .setComponent(entityID: "level", typeName: group, payload: [
                "version": .int(1), "texture": .string("checker"), "uvRepeats": .int(2),
            ]),
        ]
        let updated = try tool.applying(operations: operations, to: model)
        let entity = try #require(updated.entities.first { $0.id == "level" })
        let source = try updated.csgSource(entity)
        #expect(updated.csgBoxes(in: "level").map(\.id) == ["wall", "cut"])
        #expect(source.boxes.map { $0.shape.rawValue } == ["box", "cylinder"])
        #expect(source.boxes.map { $0.operation.rawValue } == ["union", "subtract"])
        #expect(source.uvRepeats == 2)
        #expect(source.texture == .checker)
        let invalidShape = EditorAgentSceneOperation.setComponent(
            entityID: "cut",
            typeName: block,
            payload: ["operation": .string("subtract"), "shape": .string("torus")]
        )
        #expect(throws: EditorAgentSceneToolError.self) {
            try tool.applying(operations: [invalidShape], to: updated)
        }

        let invalidPlacements: [EditorAgentSceneOperation] = [
            .reparentEntity(id: "cut", parentID: nil),
            .removeComponent(entityID: "level", typeName: group),
            .createEntity(id: "misplaced", name: "Misplaced", parentID: "cut", components: [:]),
        ]
        for operation in invalidPlacements {
            let attempt = try? tool.applying(operations: [operation], to: updated)
            #expect(attempt == nil, "A CSG block must remain a leaf child of a CSG group")
        }
    }
}
