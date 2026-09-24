@testable import AdaApp
import AdaECS
@testable import AdaScripting
import Testing

@Suite("AdaScript suspension policy", .serialized)
struct AdaScriptNonSendableTests {
    @Test("Annotated engine callbacks remain synchronous")
    @MainActor
    func rejectsAsyncLifecycleCallbacks() throws {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(source: "@system class S { async func update(anyName) {} }")
        }
        let sources = [AdaScriptSource(path: "View.ada", source: "@view class V { async func body() { Text(\"x\"); } }")]
        #expect(throws: AdaScriptError.self) {
            try AdaScriptViewModuleRuntime(sources: sources, views: AdaScriptViewScanner.declarations(in: sources))
        }
        let scriptable = AdaScriptObjectSchema(
            identifier: "test.async-scriptable-callback",
            className: "ScriptableValue",
            version: 1,
            aliases: [],
            fields: [:]
        )
        #expect(throws: AdaScriptError.self) {
            try AdaScriptObjectRegistration.register(
                schemas: [scriptable],
                sources: [
                    AdaScriptSource(
                        path: "Scriptable.ada",
                        source: "@scriptable(id: \"test.async-scriptable-callback\", version: 1)\nclass ScriptableValue { async func ready(anyName) {} }"
                    )
                ],
                moduleName: "AsyncScriptableCallbackTest"
            )
        }
    }

    @Test("Borrowed context and query aliases cannot enter a coroutine")
    @MainActor
    func rejectsBorrowedCaptures() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var attempted = false;
        async func waitFor(value) { await Tasks.nextFrame(); }
        @system class BorrowSystem {
            @query(AsyncPosition) var positions;
            func update(anyName) {
                if (!attempted) {
                    attempted = true;
                    var renamed = anyName;
                    Tasks.start(waitFor(renamed));
                    for (var row in positions) { Tasks.start(waitFor([row])); }
                }
            }
        }
        """)
        let world = World(name: "Borrowed suspension test")
        world.spawn { AsyncPosition(value: 1) }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.activeAsyncTaskCount == 0)
        #expect(plugin.diagnostics.contains(where: { $0.contains("ADASCRIPT_NONSENDABLE") && $0.contains("AdaSystemContext") }))
        #expect(plugin.diagnostics.contains(where: { $0.contains("ADASCRIPT_NONSENDABLE") && $0.contains("AdaQueryRow") }))
    }

    @Test("Script-owned @nonsendable types are rejected even through untyped parameters")
    @MainActor
    func rejectsScriptMarkedType() async throws {
        let plugin = try AdaScriptPlugin(source: """
        @nonsendable class BorrowedValue {}
        var attempted = false;
        async func waitFor(value) { await Tasks.nextFrame(); }
        @system class BorrowSystem {
            func update(anyName) {
                if (!attempted) {
                    attempted = true;
                    Tasks.start(waitFor(BorrowedValue()));
                }
            }
        }
        """)
        let world = World(name: "Marked suspension test")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.activeAsyncTaskCount == 0)
        #expect(plugin.diagnostics.contains(where: { $0.contains("@nonsendable type 'BorrowedValue'") }))
    }

    @Test("An imported @nonsendable type protects typed async parameters")
    func rejectsImportedMarkedType() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(sources: [
                AdaScriptSource(path: "Main.ada", source: """
                import { BorrowedValue } from "./Borrowed";
                async func inspect(value: BorrowedValue) { await Tasks.nextFrame(); }
                @system class S { func update(anyName) {} }
                """),
                AdaScriptSource(path: "Borrowed.ada", source: "@nonsendable class BorrowedValue {}")
            ], name: "ImportedBorrowedType")
        }
    }

    @Test("A promise cannot deliver a borrowed callback value")
    @MainActor
    func rejectsBorrowedPromiseResult() async throws {
        let plugin = try AdaScriptPlugin(source: """
        var signal = Tasks.promise();
        @system class S {
            func update(anyName) { signal.complete(anyName); }
        }
        """)
        let world = World(name: "Borrowed promise result")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.contains(where: { $0.contains("ADASCRIPT_NONSENDABLE") && $0.contains("AdaSystemContext") }))
    }
}
