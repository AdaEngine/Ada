import AdaScriptCompilerCore
import AdaScripting
import Testing

@Suite("Animation Tool runtime", .serialized)
@MainActor
struct AnimationToolRuntimeTests {
    @Test func apiTwoStagesDetachedAnimationJobsFromRealScriptMaps() throws {
        let source = AdaScriptSource(path: "AnimationTool.ada", source: """
            @tool(id: "test.animations", api: 2, platforms: ["macos", "windows"], permissions: ["editor.animations.read"])
            class AnimationTool {
                @export var job = "";
                @export var status = "";
                func activate(editor) { editor.addPanel(id: "main", title: "Animation", location: "right", ui: "Panel.ui"); }
                func inspect(editor) {
                    job = editor.animations.submit(["action": "inspect", "path": "Assets/Test.animlib"]);
                    status = editor.animations.poll(job)["status"];
                }
            }
            """)
        let schemas = try? AdaScriptSchemaParser.parseTools(sources: [source])
        #expect(schemas?.count == 1)
        guard let schema = schemas?.first else { return }
        let runtime = try? AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        #expect(runtime != nil)
        guard let runtime else { return }
        defer { runtime.deactivate() }
        try runtime.activate()
        #expect(try runtime.perform("inspect", inputs: [:], scene: nil).isEmpty)
        #expect(runtime.values["job"] != .string(""))
        #expect(runtime.values["status"] == .string("pending"))
    }

    @Test func completedResultsAreDetachedConsumedAndRetiredWithTheVM() throws {
        let runtime = try makeRuntime()
        defer { runtime.deactivate() }
        try runtime.activate()
        _ = try runtime.perform("inspect", inputs: [:], scene: nil)
        let job = try #require(runtime.takeAnimationJobs().first)
        #expect(job.request.path == "Assets/Test.animlib")
        #expect(job.request.action == .inspect)
        #expect(runtime.takeAnimationJobs().isEmpty)
        try runtime.completeAnimationJob(job.id, responseJSON: #"{"status":"completed","result":{"revision":"r1"}}"#)
        _ = try runtime.perform("poll", inputs: [:], scene: nil)
        #expect(runtime.values["status"] == .string("completed"))
        #expect(runtime.values["revision"] == .string("r1"))
        #expect(throws: AdaScriptError.self) { _ = try runtime.perform("poll", inputs: [:], scene: nil) }
        #expect(!runtime.isFailed)
        _ = try runtime.perform("inspect", inputs: [:], scene: nil)
        runtime.deactivate()
        #expect(runtime.takeAnimationJobs().isEmpty)
        #expect(throws: AdaScriptError.self) { _ = try runtime.perform("inspect", inputs: [:], scene: nil) }
    }

    @Test(arguments: ["write", "preview", "overflow", "failAfterSubmit"])
    func rejectedOrFailedCallbacksPublishNoJobs(_ action: String) throws {
        let runtime = try makeRuntime()
        defer { runtime.deactivate() }
        try runtime.activate()
        #expect(throws: AdaScriptError.self) { _ = try runtime.perform(action, inputs: [:], scene: nil) }
        #expect(runtime.takeAnimationJobs().isEmpty)
    }

    @Test func retainedJobsHaveABoundedLifetimeAndInputBudget() throws {
        let runtime = try makeRuntime()
        defer { runtime.deactivate() }
        try runtime.activate()
        for _ in 0..<16 {
            _ = try runtime.perform("inspect", inputs: [:], scene: nil)
            #expect(runtime.takeAnimationJobs().count == 1)
        }
        #expect(throws: AdaScriptError.self) { _ = try runtime.perform("inspect", inputs: [:], scene: nil) }
        #expect(runtime.takeAnimationJobs().isEmpty)
        let inputRuntime = try makeRuntime()
        defer { inputRuntime.deactivate() }
        try inputRuntime.activate()
        #expect(throws: AdaScriptError.self) {
            _ = try inputRuntime.perform("large", inputs: ["payload": .string(String(repeating: "x", count: 65_536))], scene: nil)
        }
    }

    @Test func oldDocumentGrantsDoNotConferAnimationAccess() throws {
        let runtime = try makeRuntime(api: 1, permissions: ["editor.documents.read", "editor.documents.write"])
        defer { runtime.deactivate() }
        try runtime.activate()
        #expect(throws: AdaScriptError.self) { _ = try runtime.perform("inspect", inputs: [:], scene: nil) }
        #expect(runtime.takeAnimationJobs().isEmpty)
    }

    private func makeRuntime(api: Int = 2, permissions: [String] = ["editor.animations.read"]) throws -> AdaScriptToolRuntime {
        let names = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let source = AdaScriptSource(path: "AnimationTool.ada", source: """
            @tool(id: "test.jobs", api: \(api), platforms: ["macos", "windows"], permissions: [\(names)])
            class AnimationTool {
                @export var job = "";
                @export var status = "";
                @export var revision = "";
                @export var payload = "";
                func activate(editor) { editor.addPanel(id: "main", title: "Animation", location: "right", ui: "Panel.ui"); }
                func inspect(editor) { job = editor.animations.submit(["action": "inspect", "path": "Assets/Test.animlib"]); }
                func poll(editor) {
                    var result = editor.animations.poll(job);
                    if (result["status"] != null) { status = result["status"]; }
                    if (result["result"] != null) { revision = result["result"]["revision"]; }
                }
                func write(editor) { job = editor.animations.submit(["action": "save", "path": "Assets/Test.animlib"]); }
                func preview(editor) { job = editor.animations.submit(["action": "preview", "path": "Assets/Test.animlib"]); }
                func overflow(editor) { var i = 0; while (i < 9) { inspect(editor); i += 1; } }
                func failAfterSubmit(editor) { inspect(editor); editor.createEntity(name: "Denied", x: 0.0, y: 0.0); }
                func large(editor) { job = editor.animations.submit(["action": "inspect", "path": payload]); }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        return try .init(sources: [source], schema: schema, grantedPermissions: schema.permissions)
    }
}
