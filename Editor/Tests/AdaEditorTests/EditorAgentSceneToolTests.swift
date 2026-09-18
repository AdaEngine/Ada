import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor agent scene tools")
@MainActor
struct EditorAgentSceneToolTests {
    @Test("scene operations apply atomically and can be undone")
    func applyAndUndo() throws {
        let fixture = try makeFixture(named: "ApplyUndo")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let service = EditorAgentSceneToolService(projectURL: fixture.projectURL)
        let before = try service.snapshot(relativePath: fixture.scenePath)

        let result = try service.apply(
            relativePath: fixture.scenePath,
            expectedRevision: before.revision,
            operations: [
                .createEntity(id: "player", name: "Player", parentID: "root", components: [:]),
                .setEntityEnabled(id: "player", enabled: false),
                .renameEntity(id: "root", name: "Game Root"),
            ]
        )

        #expect(result.previousRevision == before.revision)
        #expect(result.revision != before.revision)
        #expect(result.model.entities.first { $0.id == "player" }?.parent == "root")
        #expect(result.model.entities.first { $0.id == "player" }?.enabled == false)
        #expect(result.model.entities.first { $0.id == "player" }?.components[EditorBuiltInComponentType.transform] != nil)
        #expect(service.listScenes() == [fixture.scenePath])

        let restored = try service.undo(changeID: result.changeID)
        #expect(restored.model == before.model)
        #expect(restored.revision == before.revision)
    }

    @Test("stale revisions reject the whole scene batch")
    func rejectsStaleRevision() throws {
        let fixture = try makeFixture(named: "Revision")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let service = EditorAgentSceneToolService(projectURL: fixture.projectURL)
        let before = try service.snapshot(relativePath: fixture.scenePath)

        #expect(throws: EditorAgentSceneToolError.revisionConflict(expected: "stale", actual: before.revision)) {
            try service.apply(
                relativePath: fixture.scenePath,
                expectedRevision: "stale",
                operations: [.renameEntity(id: "root", name: "Changed")]
            )
        }
        #expect(try service.snapshot(relativePath: fixture.scenePath).model == before.model)
    }

    @Test("scene hierarchy rejects cycles without writing")
    func rejectsHierarchyCycle() throws {
        let fixture = try makeFixture(named: "Cycle")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let service = EditorAgentSceneToolService(projectURL: fixture.projectURL)
        let before = try service.snapshot(relativePath: fixture.scenePath)

        #expect(throws: EditorAgentSceneToolError.hierarchyCycle("root")) {
            try service.apply(
                relativePath: fixture.scenePath,
                expectedRevision: before.revision,
                operations: [
                    .createEntity(id: "child", name: "Child", parentID: "root", components: [:]),
                    .reparentEntity(id: "root", parentID: "child"),
                ]
            )
        }
        #expect(try service.snapshot(relativePath: fixture.scenePath).model == before.model)
    }

    @Test("delete can reparent children and undo detects later edits")
    func deleteAndUndoConflict() throws {
        let fixture = try makeFixture(named: "Delete")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let service = EditorAgentSceneToolService(projectURL: fixture.projectURL)
        let before = try service.snapshot(relativePath: fixture.scenePath)
        let added = try service.apply(
            relativePath: fixture.scenePath,
            expectedRevision: before.revision,
            operations: [
                .createEntity(id: "parent", name: "Parent", parentID: "root", components: [:]),
                .createEntity(id: "child", name: "Child", parentID: "parent", components: [:]),
            ]
        )
        let deleted = try service.apply(
            relativePath: fixture.scenePath,
            expectedRevision: added.revision,
            operations: [.deleteEntity(id: "parent", children: .reparent)]
        )

        #expect(deleted.model.entities.first { $0.id == "child" }?.parent == "root")

        let sceneURL = fixture.projectURL.appendingPathComponent(fixture.scenePath)
        try "external change".write(to: sceneURL, atomically: true, encoding: .utf8)
        #expect(throws: EditorAgentSceneToolError.self) {
            try service.undo(changeID: deleted.changeID)
        }
    }

    @Test("scene paths cannot escape the project")
    func rejectsEscapingPath() throws {
        let fixture = try makeFixture(named: "Path")
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }
        let service = EditorAgentSceneToolService(projectURL: fixture.projectURL)

        #expect(throws: EditorAgentSceneToolError.invalidScenePath("../Outside.ascn")) {
            try service.snapshot(relativePath: "../Outside.ascn")
        }
    }

    private func makeFixture(named name: String) throws -> (projectURL: URL, scenePath: String) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAgentSceneToolTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let scenePath = "Assets/Scenes/Main.ascn"
        let sceneURL = projectURL.appendingPathComponent(scenePath)
        try FileManager.default.createDirectory(at: sceneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EditorSceneModel.default(projectName: name).encodedYAML().write(to: sceneURL, atomically: true, encoding: .utf8)
        return (projectURL, scenePath)
    }
}
