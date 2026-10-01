#if canImport(GravityAOT)
@testable import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaScene
import AdaScriptAOTFixture
@testable import AdaScripting
import Foundation
import GravityAOT
import Testing

@Suite("Native AdaScript async", .serialized)
struct AdaScriptNativeAsyncTests {
    private func makeModule(fuel: UInt64 = 1_000_000) throws -> NativeModule {
        let pointer = try #require(ada_native_async_get_module())
        return unsafe try NativeModule(module: pointer, fuelPerCall: fuel)
    }
    private func task(_ value: NativeValue) throws -> NativeTask {
        guard case .task(let task) = value else { throw AdaScriptError.invalidManifest("Expected native task") }
        return task
    }

    @Test("Nested await preserves loop locals and expression values without replay")
    func nestedAwait() throws {
        let module = try makeModule()
        let runtime = NativeAsyncRuntime(module: module)
        let instance = try module.makeInstance(type: "NativeAsyncProbe")
        let pending = try task(module.invoke(instance, method: "nested", globals: runtime.globals))
        #expect(try module.read(instance, field: "counter").literal == .integer(0))
        for _ in 0..<2 {
            runtime.advance(deltaTime: 0.01)
            guard case .pending = try module.poll(pending, globals: runtime.globals) else { Issue.record("Task completed early"); return }
        }
        runtime.advance(deltaTime: 0.01)
        guard case .completed(let value) = try module.poll(pending, globals: runtime.globals) else { Issue.record("Task did not complete"); return }
        #expect(value.literal == .integer(12))
        #expect(try module.read(instance, field: "counter").literal == .integer(12))
        guard case .completed(let again) = try module.poll(pending, globals: runtime.globals) else { Issue.record("Completed task changed state"); return }
        #expect(again.literal == .integer(12))
        let immediate = try task(module.invoke(instance, method: "immediate"))
        guard case .completed(let nine) = try module.poll(immediate) else { Issue.record("Immediate task pending"); return }
        #expect(nine.literal == .integer(9))
    }

    @Test("Tasks.start executes after synchronous callback statements in the same valid scope")
    func callbackOrdering() throws {
        let module = try makeModule()
        let runtime = NativeAsyncRuntime(module: module)
        let instance = try module.makeInstance(type: "NativeAsyncProbe")
        _ = try module.invoke(instance, method: "begin", globals: runtime.globals)
        #expect(try module.read(instance, field: "counter").literal == .integer(7))
        runtime.advance(deltaTime: 0.01)
        runtime.resume(receiver: instance, bindings: [:], globals: runtime.globals, recorder: NativeDiagnostics())
        #expect(try module.read(instance, field: "counter").literal == .integer(8))
    }

    @Test("Long-running frame waits release detached host operations")
    func longRunningTimers() throws {
        let module = try makeModule()
        let runtime = NativeAsyncRuntime(module: module)
        let instance = try module.makeInstance(type: "NativeAsyncProbe")
        let pending = try task(module.invoke(instance, method: "longLoop", globals: runtime.globals))
        for frame in 1...5000 {
            runtime.advance(deltaTime: 0.01)
            let status = try module.poll(pending, globals: runtime.globals)
            if frame == 5000 {
                guard case .completed(let result) = status else { Issue.record("Long task did not complete"); return }
                #expect(result.literal == .integer(5000))
            } else if case .completed = status { Issue.record("Long task completed early"); return }
        }
    }

    @Test("Detached host handles survive when retained inside native lists and fields")
    func retainedOperations() throws {
        let module = try makeModule()
        let instance = try module.makeInstance(type: "NativeAsyncProbe")
        let values: [NativeValue] = (0..<300).map { _ in
            let operation = AdaScriptAsyncOperation()
            operation.complete(.success())
            return .host(NativeOperationHost(operation))
        }
        _ = try module.invoke(instance, method: "retain", arguments: [.list(values)])
        #expect(try module.invoke(instance, method: "retainedComplete").literal == .boolean(true))
        _ = try module.invoke(instance, method: "clearRetained")
        _ = try module.invoke(instance, method: "retain", arguments: [.list([values[0]])])
        #expect(try module.invoke(instance, method: "retainedComplete").literal == .boolean(true))
    }

    @Test("Cancellation propagates through awaits and borrowed context expires")
    func cancellationAndCapabilities() throws {
        let module = try makeModule()
        let runtime = NativeAsyncRuntime(module: module)
        let instance = try module.makeInstance(type: "NativeAsyncProbe")
        let scope = NativeCallbackScope()
        let context = NativeSystemContext(scope: scope, deltaTime: 0.25)
        let pending = try task(module.invoke(instance, method: "stale", arguments: [.host(context)], globals: runtime.globals))
        #expect(try module.read(instance, field: "counter").literal == .integer(1))
        scope.isActive = false
        runtime.advance(deltaTime: 0.01)
        #expect(throws: NativeRuntimeError.self) { _ = try module.poll(pending, globals: runtime.globals) }
        #expect(try module.read(instance, field: "counter").literal == .integer(1))
        let nested = try task(module.invoke(instance, method: "nested", globals: runtime.globals))
        try module.cancel(nested)
        runtime.advance(deltaTime: 1)
        guard case .cancelled = try module.poll(nested, globals: runtime.globals) else { Issue.record("Cancelled task resumed"); return }
        #expect(try module.read(instance, field: "counter").literal == .integer(1))
        let limited = try makeModule(fuel: 32)
        let probe = try limited.makeInstance(type: "NativeAsyncProbe")
        #expect(throws: NativeRuntimeError.self) { _ = try limited.invoke(probe, method: "infinite") }
    }

    @Test("ECS owner resumes with declared bindings, game clock, and promise results")
    @MainActor
    func nativeScheduler() async throws {
        let plugin = try AdaScriptNativePlugin(module: makeModule(), name: "NativeAsyncScheduler")
        let world = World()
        let app = AppWorlds(main: world)
        plugin.setup(in: app)
        #expect(plugin.diagnostics.isEmpty)
        for _ in 0..<8 {
            world.insertResource(DeltaTime(deltaTime: 0.1))
            await world.runScheduler(.update, deltaTime: 0.1)
        }
        #expect(world.getResource(AdaScriptNativeResources.self)?.values["aot.async.stats"]?["result"] == .int(42))
        #expect(world.getResource(AdaScriptNativeResources.self)?.values["aot.async.stats"]?["done"] == .bool(true))
        #expect(plugin.diagnostics.isEmpty)
        plugin.destroy(for: app)
    }

    @Test("Scene replacement cancels waiting system tasks")
    @MainActor
    func sceneReplacementCancelsTasks() async throws {
        let plugin = try AdaScriptNativePlugin(module: makeModule(), name: "NativeAsyncSceneReplacement")
        let world = World()
        let app = AppWorlds(main: world)
        let navigator = SceneNavigator(world: world)
        world.insertResource(navigator)
        navigator.installInitialScene(Scene(name: "First"), make: { Scene(name: "First") })
        plugin.setup(in: app)
        world.insertResource(DeltaTime(deltaTime: 0.1))
        await world.runScheduler(.update, deltaTime: 0.1)
        navigator.installInitialScene(Scene(name: "Second"), make: { Scene(name: "Second") })
        for _ in 0..<8 { await world.runScheduler(.update, deltaTime: 0.1) }
        #expect(world.getResource(AdaScriptNativeResources.self)?.values["aot.async.stats"]?["done"] == .bool(false))
        #expect(plugin.diagnostics.isEmpty)
        plugin.destroy(for: app)
    }

    @Test("Ready tasks run without an update method and stop when their scriptable is removed")
    @MainActor
    func nativeScriptable() async throws {
        let plugin = try AdaScriptNativePlugin(module: makeModule(), name: "NativeAsyncLifecycle")
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        plugin.setup(in: app)
        let script = try ScriptableObjectRegistry.make(named: "aot.async.controller")
        let entity = world.spawn { ScriptableComponents(scripts: [script]) }
        for _ in 0..<3 { await world.runScheduler(.update, deltaTime: 0.1) }
        let before = script.readExportedField("frames")
        guard case .int(let frames) = before else { Issue.record("No frame count"); return }
        #expect(frames > 0 && frames < 10)
        world.removeEntity(entity.id)
        await world.runScheduler(.update, deltaTime: 0.1)
        await world.runScheduler(.update, deltaTime: 0.1)
        #expect(script.readExportedField("frames") == before)
        #expect(plugin.diagnostics.isEmpty)
        plugin.destroy(for: app)
    }
}
#endif
