import AdaScriptCompilerCore
import AdaScripting
import Foundation
import Testing

extension AnimationToolRuntimeTests {
    @Test func graphRequestsCarryDetachedPoseGraphDataFromRealTools() throws {
        let runtime = try graphRuntime(permissions: ["editor.animations.read", "editor.animations.write"])
        defer { runtime.deactivate() }
        try runtime.activate()
        let result = try? runtime.perform("configure", inputs: [:], scene: nil)
        #expect(result != nil)
        let jobs = runtime.takeAnimationJobs()
        #expect(jobs.count == 1)
        guard let job = jobs.first else { return }
        let encoded = try JSONEncoder().encode(job.request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((object["graph"] as? [String: Any])?["root"] as? String == "Output")
    }

    @Test(arguments: [("graphApply", "editor.animations.write"), ("graphPreview", "editor.animations.preview"), ("graphBind", "editor.documents.write")])
    func graphActionsEnforceTheirSpecificHostPermissions(_ action: String, _ permission: String) throws {
        let runtime = try graphRuntime(permissions: ["editor.animations.read"])
        defer { runtime.deactivate() }
        try runtime.activate()
        do {
            _ = try runtime.perform("request", inputs: ["operation": .string(action)], scene: nil)
            Issue.record("A graph action must require its specific permission.")
        } catch {
            #expect(error.localizedDescription.contains(permission))
        }
        #expect(runtime.takeAnimationJobs().isEmpty)
    }

    private func graphRuntime(permissions: [String]) throws -> AdaScriptToolRuntime {
        let names = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let source = AdaScriptSource(path: "GraphTool.ada", source: """
            @tool(id: "test.graph", api: 2, platforms: ["macos", "windows"], permissions: [\(names)])
            class GraphTool {
                @export var job = "";
                @export var operation = "graphApply";
                func activate(editor) { editor.addPanel(id: "main", title: "Graph", location: "right", ui: "Panel.ui"); }
                func configure(editor) {
                    job = editor.animations.submit(["action": "graphApply", "path": "Assets/Robot.glb", "expectedRevision": "graph-revision",
                        "graph": ["root": "Output", "nodes": []]]);
                }
                func request(editor) { job = editor.animations.submit(["action": operation, "path": "Assets/Robot.glb"]); }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        return try .init(sources: [source], schema: schema, grantedPermissions: schema.permissions)
    }
}
