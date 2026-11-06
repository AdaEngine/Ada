import AdaScriptCompilerCore
import AdaScripting
import Foundation
import Testing

extension AnimationToolRuntimeTests {
    @Test(arguments: [("modifierApply", "editor.animations.write"), ("modifierPreview", "editor.animations.preview"), ("modifierBind", "editor.documents.write")])
    func ikActionsEnforceTheirSpecificHostPermissions(_ action: String, _ permission: String) throws {
        let runtime = try modifierRuntime(permissions: ["editor.animations.read"])
        defer { runtime.deactivate() }
        try runtime.activate()
        do {
            _ = try runtime.perform("request", inputs: ["operation": .string(action)], scene: nil)
            Issue.record("IK actions must require their specific permissions.")
        } catch { #expect(error.localizedDescription.contains(permission)) }
        #expect(runtime.takeAnimationJobs().isEmpty)
    }

    @Test
    func realToolsCarryTypedIKCommandsWithoutRetainingSceneObjects() throws {
        let runtime = try modifierRuntime(permissions: ["editor.animations.read", "editor.animations.write"])
        defer { runtime.deactivate() }
        try runtime.activate()
        _ = try runtime.perform("configure", inputs: [:], scene: nil)
        let jobs = runtime.takeAnimationJobs()
        #expect(jobs.count == 1)
        let request = try #require(jobs.first).request
        #expect(request.action.rawValue == "modifierApply")
        let command = try #require(request.modifierOperations?.first)
        #expect(command.modifier?.joints == ["shoulder", "elbow", "wrist"])
        #expect(command.modifier?.influence == 0.5)
    }

    private func modifierRuntime(permissions: [String]) throws -> AdaScriptToolRuntime {
        let names = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let source = AdaScriptSource(path: "IKTool.ada", source: """
            @tool(id: "test.ik", api: 2, platforms: ["macos", "windows"], permissions: [\(names)])
            class IKTool {
                @export var operation = "modifierInspect";
                func activate(editor) { editor.addPanel(id: "main", title: "IK", location: "right", ui: "Panel.ui"); }
                func request(editor) { editor.animations.submit(["action": operation, "path": "Assets/Arm.animmod"]); }
                func configure(editor) {
                    editor.animations.submit(["action": "modifierApply", "path": "Assets/Arm.animmod", "expectedRevision": "current",
                        "modifierOperations": [["kind": "add", "modifier": ["id": "arm", "kind": "twoBone",
                            "joints": ["shoulder", "elbow", "wrist"], "target": ["x": 1, "y": 1, "z": 0],
                            "enabled": true, "influence": 0.5, "iterations": 16]]]]);
                }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        return try .init(sources: [source], schema: schema, grantedPermissions: schema.permissions)
    }
}
