@testable import AdaEditor
import Foundation
import Testing

@MainActor
@Suite("Mobile Studio scene validation", .serialized)
struct MobileEditorSceneValidationTests {
    @Test("The mobile build check loads a real scene and rejects unknown components")
    func rejectsUnknownComponentAndAcceptsRepair() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent(SceneDocumentFormat.defaultScenePath)
        var model = try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        let entity = model.addEntity(name: "Player")
        let index = try #require(model.entities.firstIndex { $0.id == entity.id })
        model.entities[index].components["Game.MissingMovement"] = [:]
        try model.encodedYAML().write(to: sceneURL, atomically: true, encoding: .utf8)

        let project = try ProjectSystem.loadProject(at: root)
        // Compilation and YAML parsing alone used to report success for this project.
        let broken = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        do {
            try MobileEditorSceneValidation.validate(broken, at: root)
            Issue.record("The mobile check accepted an unknown component")
        } catch let error as EditorAdaScriptProjectBuildError {
            guard case let .startupSceneInvalid(path, message) = error else { throw error }
            #expect(path == SceneDocumentFormat.defaultScenePath)
            #expect(message.contains("Unknown component: Game.MissingMovement"))
        }

        model.entities[index].components.removeValue(forKey: "Game.MissingMovement")
        try model.encodedYAML().write(to: sceneURL, atomically: true, encoding: .utf8)
        let repaired = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        try MobileEditorSceneValidation.validate(repaired, at: root)
    }

    @Test("The mobile build check follows nested scene references")
    func rejectsUnknownComponentInNestedScene() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent(SceneDocumentFormat.defaultScenePath)
        var model = try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        let entity = model.addEntity(name: "Nested")
        let index = try #require(model.entities.firstIndex { $0.id == entity.id })
        model.entities[index].components[EditorBuiltInComponentType.sceneInstance] = ["scene": .string("@res://Scenes/Enemy.ascn")]
        try model.encodedYAML().write(to: sceneURL, atomically: true, encoding: .utf8)
        let nestedURL = root.appendingPathComponent("Assets/Scenes/Enemy.ascn")
        var nested = try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        nested.entities[index].components = ["Game.MissingEnemy": [:]]
        try nested.encodedYAML().write(to: nestedURL, atomically: true, encoding: .utf8)

        let project = try ProjectSystem.loadProject(at: root)
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        do {
            try MobileEditorSceneValidation.validate(artifact, at: root)
            Issue.record("The mobile check accepted an invalid nested scene")
        } catch let error as EditorAdaScriptProjectBuildError {
            #expect(error.localizedDescription.contains("@res://Scenes/Enemy.ascn"))
            #expect(error.localizedDescription.contains("Unknown component: Game.MissingEnemy"))
        }
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSceneValidation-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "Mobile Game", buildSystem: .adaScript)
        project.runtime.entry = .init(scene: SceneDocumentFormat.defaultScenePath)
        try ProjectSystem.saveProject(project, at: root)
        try "// Scene validation fixture\n".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        // An empty scene avoids renderer setup while still using the production YAML and loader paths.
        var model = try EditorSceneModel.decode(from: SceneDocumentFormat.defaultSceneYAML(projectName: "Mobile Game"))
        model.entities = []
        try model.encodedYAML().write(to: root.appendingPathComponent(SceneDocumentFormat.defaultScenePath), atomically: true, encoding: .utf8)
        return root
    }
}
