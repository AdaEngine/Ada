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

@Suite("Native AdaScript integration", .serialized)
struct AdaScriptNativeTests {
    @Test("Compiled systems use real query filters, native schemas, resources and scheduler dependencies")
    @MainActor
    func runsNativeSystems() async throws {
        NativeVelocity.registerComponent()
        NativeMovable.registerComponent()
        NativeFrozen.registerComponent()
        let module = try #require(ada_native_fixture_get_module())
        let runtime = unsafe try NativeModule(module: module)
        let plugin = try AdaScriptNativePlugin(module: runtime, name: "NativeMovementProof")
        let world = World(name: "Native AdaScript world")
        world.insertResource(DeltaTime(deltaTime: 2))
        plugin.setup(in: AppWorlds(main: world))
        #expect(plugin.diagnostics.isEmpty)
        let position = try #require(world.runtimeComponentDescriptor(named: "PositionData"))
        func payload(_ value: Double) -> RuntimeComponentPayload {
            RuntimeComponentPayload(componentID: position.componentID, stableID: position.stableID, values: [.double(value)])
        }
        let first = world.spawn {
            payload(1)
            NativeVelocity(value: 3)
            NativeMovable()
        }
        let second = world.spawn {
            payload(10)
            NativeVelocity(value: -2)
            NativeMovable()
        }
        let frozen = world.spawn {
            payload(20)
            NativeVelocity(value: 100)
            NativeMovable()
            NativeFrozen()
        }
        let inactive = world.spawn {
            payload(50)
            NativeVelocity(value: 100)
            NativeMovable()
        }
        inactive.isActive = false
        let noMarker = world.spawn {
            payload(60)
            NativeVelocity(value: 100)
        }
        let field = try #require(position.fields.first(where: { $0.key == "value" }))
        await world.runScheduler(.update, deltaTime: 2)
        #expect(plugin.diagnostics.isEmpty)
        #expect(world.readComponentField(component: position.componentID, entity: first.id, field: field) == .double(19))
        #expect(world.readComponentField(component: position.componentID, entity: second.id, field: field) == .double(-2))
        #expect(world.readComponentField(component: position.componentID, entity: frozen.id, field: field) == .double(20))
        #expect(world.readComponentField(component: position.componentID, entity: inactive.id, field: field) == .double(50))
        #expect(world.readComponentField(component: position.componentID, entity: noMarker.id, field: field) == .double(60))
        #expect(world.getResource(AdaScriptNativeResources.self)?.values["aot.integration.time"]?["factor"] == .double(3))
        // The cursor must pick up new archetypes rather than caching entity snapshots.
        let added = world.spawn {
            payload(100)
            NativeVelocity(value: 1)
            NativeMovable()
        }
        await world.runScheduler(.update, deltaTime: 2)
        #expect(world.readComponentField(component: position.componentID, entity: added.id, field: field) == .double(108))
        #expect(world.readComponentField(component: position.componentID, entity: first.id, field: field) == .double(43))
        plugin.destroy(for: AppWorlds(main: world))
        await world.runScheduler(.update, deltaTime: 2)
        #expect(world.readComponentField(component: position.componentID, entity: first.id, field: field) == .double(43))
    }

    @Test("Native scriptable objects participate in lifecycle and Codable registry envelopes")
    @MainActor
    func scriptableLifecycle() async throws {
        NativeVelocity.registerComponent()
        NativeMovable.registerComponent()
        NativeFrozen.registerComponent()
        let pointer = try #require(ada_native_fixture_get_module())
        let runtime = unsafe try NativeModule(module: pointer)
        let plugin = try AdaScriptNativePlugin(module: runtime, name: "NativeScriptableProof")
        let world = World(name: "Native scriptable world")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.insertResource(DeltaTime(deltaTime: 0.01))
        plugin.setup(in: app)
        #expect(plugin.diagnostics.isEmpty)
        let descriptor = try #require(world.runtimeComponentDescriptor(named: "PositionData"))
        let script = try ScriptableObjectRegistry.make(named: "NativeController")
        let entity = world.spawn {
            descriptor.makeDefault()
            ScriptableComponents(scripts: [script])
        }
        await world.runScheduler(.update, deltaTime: 0.01)
        #expect(plugin.diagnostics.isEmpty)
        #expect(script.readExportedField("health") == .int(11))
        let field = try #require(descriptor.fields.first)
        let value = world.readComponentField(component: descriptor.componentID, entity: entity.id, field: field)
        if case .double(let number) = value { #expect(abs(number - 0.01) < 0.0001) } else { Issue.record("Native position was not updated") }
        #expect(script.writeExportedField("health", value: .int(25)))
        let encoded = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
        let detached = try JSONDecoder().decode(ScriptableComponents.self, from: encoded)
        #expect(detached.scripts.first?.readExportedField("health") == .int(25))
        world.remove(ScriptableComponents.self, from: entity.id)
        await world.runScheduler(.update, deltaTime: 0.01)
        #expect(script.readExportedField("health") == .int(0))
        #expect(plugin.diagnostics.isEmpty)
        // Entity removal invalidates its component storage before destroy runs.
        let disappearing = try ScriptableObjectRegistry.make(named: "NativeController")
        let removedEntity = world.spawn { descriptor.makeDefault(); ScriptableComponents(scripts: [disappearing]) }
        await world.runScheduler(.update, deltaTime: 0.01)
        world.removeEntity(removedEntity.id)
        await world.runScheduler(.update, deltaTime: 0.01)
        await world.runScheduler(.update, deltaTime: 0.01)
        #expect(disappearing.readExportedField("health") == .int(0))
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("Failed native host operations are diagnostics without a VM fallback")
    @MainActor
    func nativeFailure() throws {
        let pointer = try #require(ada_native_fixture_get_module())
        let runtime = unsafe try NativeModule(module: pointer)
        let instance = try runtime.makeInstance(type: "MovementSystem")
        #expect(throws: NativeRuntimeError.self) {
            _ = try runtime.invoke(instance, method: "update", arguments: [.null])
        }
        #expect(throws: NativeRuntimeError.self) { _ = try runtime.invoke(instance, method: "missing") }
        // A runtime error must not poison subsequent invocations or reflection.
        #expect(try runtime.read(instance, field: "updates").literal == .integer(0))
    }
}

@Component private struct NativeVelocity { var value: Double = 0 }
@Component private struct NativeMovable {}
@Component private struct NativeFrozen {}
#endif
