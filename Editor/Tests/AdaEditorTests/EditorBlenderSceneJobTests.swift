#if os(Windows)
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Blender scene jobs", .serialized)
struct EditorBlenderSceneJobTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_BLENDER_MCP_TEST_EXECUTABLE"] != nil))
    func exportsImportsAndPlacesOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Ada Blender Scene \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let starter = try #require(EditorAgentKnowledge.examples.first { $0.id == "basic-3d-scene" })
        for (path, content) in starter.files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
        let scene = SceneDocumentFormat.defaultScenePath
        let content = try #require(starter.files[scene])
        let editor = EditorViewModel(project: EditorProjectReference(name: "Basic 3D", path: root.path))
        editor.workbench.open(.scene(.init(
            id: scene,
            title: "Main.ascn",
            relativePath: scene,
            absolutePath: root.appendingPathComponent(scene).path,
            content: content,
            lastSavedContent: content,
            sceneModel: try EditorSceneModel.decode(from: content),
            isDirty: false,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )))
        EditorAgentMCPTools.shared.activate(editor)
        defer { EditorAgentMCPTools.shared.deactivate(editor) }

        let settings = EditorBlenderMCPSettings()
        settings.executablePath = try #require(ProcessInfo.processInfo.environment["ADA_STUDIO_BLENDER_MCP_TEST_EXECUTABLE"])
        await settings.connect()
        defer { Task { await settings.disconnect() } }
        try #require(settings.connected)
        settings.enable(true)
        let tools = settings.tools(projectURL: root, isCurrentProject: { true })
        let discovery = try #require(tools.first { $0.name == "editor_external_list" })
        let inventory = try await discovery.invoke([:])
        #expect(inventory.contains("blender.import_glb"))
        #expect(inventory.contains("blender.place_model"))
        #expect(inventory.contains("blender.verify_play"))
        let tool = try #require(tools.first { $0.name == "editor_external_invoke" })

        let recipe = try JSONDecoder().decode(EditorCloudValue.self, from: Data(Self.cone.utf8))
        let export = try await invoke(tool, "blender.create_and_export_glb", input: recipe)
        let artifact = try #require(export["artifact"].string)
        let job = try #require(artifact.split(separator: "/").dropLast().last).description
        let importInput: EditorCloudValue = ["job": .string(job), "scene": .string(scene), "destination": "Assets/Models"]
        let existing = root.appendingPathComponent("Assets/Models/Traffic Cone.glb")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Data("Existing asset".utf8)
        try unrelated.write(to: existing)
        let imported = try await invoke(tool, "blender.import_glb", input: importInput)
        let reference = try #require(imported["assetReference"].string)
        #expect(reference.hasPrefix("@res://Models/"))
        #expect(try Data(contentsOf: existing) == unrelated)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(artifact).path))
        #expect(try await invoke(tool, "blender.import_glb", input: importInput)["assetReference"].string == reference)
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path).count == 2)

        let placement: EditorCloudValue = [
            "job": .string(job), "scene": .string(scene), "expectedRevision": .string(EditorAgentSceneToolService.revision(for: content)),
            "position": [.number(1.0), .number(0.0), .number(0.0)]
        ]
        var stale = placement
        stale["expectedRevision"] = "old-revision"
        await #expect(throws: (any Error).self) { _ = try await invoke(tool, "blender.place_model", input: stale) }
        #expect(editor.workbench.activeSceneDocument?.content == content)
        let placed = try await invoke(tool, "blender.place_model", input: placement)
        let entityID = try #require(placed["entityID"].string)
        #expect(try await invoke(tool, "blender.place_model", input: placement)["entityID"].string == entityID)
        let model = try #require(editor.workbench.activeSceneDocument?.sceneModel)
        #expect(model.entities.filter { $0.id == entityID }.count == 1)
        #expect(model.entities.first { $0.id == entityID }?.components[EditorBuiltInComponentType.model3DSource]?["source"]?.stringValue == reference)
        #expect(editor.workbench.saveSceneDocument(id: scene))
        let saved = try EditorSceneModel.decode(from: String(contentsOf: root.appendingPathComponent(scene), encoding: .utf8))
        #expect(saved.entities.contains { $0.id == entityID })
    }

    private func invoke(_ tool: EditorCloudAgentTool, _ alias: String, input: EditorCloudValue) async throws -> EditorCloudValue {
        let arguments: EditorCloudValue = ["tool": .string(alias), "input": input]
        try tool.validate?(arguments)
        return try JSONDecoder().decode(EditorCloudValue.self, from: Data(try await tool.invoke(arguments).utf8))
    }

    private static let cone = """
    {"name":"Traffic Cone","parts":[
      {"shape":"box","size":[0.65,0.65,0.08],"position":[0,0,0.04],"color":[0.025,0.025,0.03]},
      {"shape":"cone","size":[0.52,0.52,0.72],"position":[0,0,0.44],"color":[0.95,0.18,0.015]}
    ]}
    """
}
#endif
