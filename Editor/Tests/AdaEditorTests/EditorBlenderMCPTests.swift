#if os(Windows)
import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Blender MCP in Ada AI", .serialized)
struct EditorBlenderMCPTests {
    @Test func recipeRejectsCodeAndPaths() throws {
        var input = try JSONDecoder().decode(EditorCloudValue.self, from: Data(Self.cone.utf8))
        _ = try EditorBlenderMCPExport.Recipe(input)
        input["path"] = "C:/OtherProject/Model.glb"
        #expect(throws: EditorBlenderMCPExport.Failure.recipe) { try EditorBlenderMCPExport.Recipe(input) }
        var fields = input.object
        fields.removeValue(forKey: "path")
        input = .object(fields)
        input["code"] = "print('unexpected')"
        #expect(throws: EditorBlenderMCPExport.Failure.recipe) { try EditorBlenderMCPExport.Recipe(input) }
    }

    @Test func exportValidationRejectsAnEmptyGLBContainer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = Data([0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0, 24, 0, 0, 0, 4, 0, 0, 0, 0x4a, 0x53, 0x4f, 0x4e, 0x7b, 0x7d, 0x20, 0x20])
        try empty.write(to: url, options: .withoutOverwriting)
        #expect(throws: EditorBlenderMCPExport.Failure.artifact) { try EditorBlenderMCPExport.validatedBytes(at: url) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_BLENDER_MCP_TEST_EXECUTABLE"] != nil))
    @MainActor func approvedAdaAIToolExportsRealBlenderCone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ada Blender QA \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = EditorBlenderMCPSettings()
        settings.executablePath = try #require(ProcessInfo.processInfo.environment["ADA_STUDIO_BLENDER_MCP_TEST_EXECUTABLE"])
        await settings.connect()
        #expect(settings.errorMessage == nil)
        try #require(settings.connected)
        #expect(settings.tools(projectURL: directory, isCurrentProject: { true }).isEmpty)
        settings.enable(true)

        let fixture = ModelFixture()
        let service = EditorCloudAgentService(connectionFactory: {
            EditorCloudAIConnection(toolContract: 2, supportsExternalTools: true) { input, receive in
                try await fixture.respond(input, receive: receive)
            }
        }, toolsFactory: { project in
            await settings.tools(projectURL: project, isCurrentProject: { project == directory })
        })
        var project = ProjectSystem.defaultProject(buildSystem: .adaScript)
        project.ai.agent.enabled = true
        let request = EditorAgentRunRequest(
            project: project,
            projectURL: directory,
            session: .init(id: "blender-test"),
            mode: .build,
            prompt: "Create an orange traffic cone in Blender and export a GLB.",
            attachments: [],
            sceneContext: nil,
            codeSelection: nil,
            skills: []
        )
        _ = try await service.send(
            request,
            onEvent: { event in
                if let permission = event.permission {
                    #expect(permission.summary.contains("Traffic Cone"))
                    await service.resolvePermission(requestID: permission.id, optionID: "allow")
                }
            },
            onProjectFileChanged: { await fixture.record($0) }
        )
        await settings.disconnect()

        let path = try #require(await fixture.artifact)
        #expect(path.hasPrefix("Downloads/Blender/"))
        let bytes = try Data(contentsOf: directory.appendingPathComponent(path))
        try EditorModelAssetImporter.requireSelfContainedGLB(bytes)
        let decoded = try NativeGLTFLoader().load(data: bytes, baseURL: directory)
        #expect(decoded.meshes.count == 2)
        let length = bytes[12..<16].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        let gltf = try JSONDecoder().decode(EditorCloudValue.self, from: bytes.subdata(in: 20..<(20 + length)))
        #expect(gltf["scenes"].array.count == 1)
        #expect(gltf["meshes"].array.count == 2)
        let colors = gltf["materials"].array.map { $0["pbrMetallicRoughness"]["baseColorFactor"].array.map(\.seconds) }
        #expect(colors.contains { $0.count == 4 && $0[0] > 0.85 && (0.10...0.30).contains($0[1]) && $0[2] < 0.05 })
        #expect(colors.contains { $0.count == 4 && $0.prefix(3).allSatisfy { $0 < 0.08 } })
    }

    private static let cone = """
    {"name":"Traffic Cone","parts":[
      {"shape":"box","size":[0.65,0.65,0.08],"position":[0,0,0.04],"color":[0.025,0.025,0.03]},
      {"shape":"cone","size":[0.52,0.52,0.72],"position":[0,0,0.44],"color":[0.95,0.18,0.015]}
    ]}
    """

    private actor ModelFixture {
        private var round = 0
        private(set) var artifact: String?

        func record(_ path: String) { artifact = path }

        func respond(_ input: EditorCloudValue, receive: @escaping @Sendable (EditorCloudValue) async throws -> Void) async throws {
            #expect(input["toolContract"].int == 3)
            #expect(input["tools"].array.contains { $0["function"]["name"].string == "editor_external" })
            round += 1
            if round == 1 {
                let arguments = "{\"action\":\"invoke\",\"arguments\":{\"tool\":\"blender.create_and_export_glb\",\"input\":\(cone)}}"
                try await receive(["type": "tool", "call": ["id": "cone", "function": ["name": "editor_external", "arguments": .string(arguments)]]])
            } else {
                try await receive(["type": "text", "text": "Export complete"])
            }
            try await receive(["type": "complete"])
        }
    }
}
#endif
