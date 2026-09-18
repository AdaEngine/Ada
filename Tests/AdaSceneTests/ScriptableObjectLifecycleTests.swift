@testable import AdaApp
import AdaECS
@_spi(Internal) import AdaInput
import AdaScene
import AdaUtils
import Foundation
import Testing

@Suite("Scriptable object lifecycle", .serialized)
struct ScriptableObjectLifecycleTests {
    @Test("Decode stays detached and lifecycle runs once in order")
    @MainActor
    func runsLifecycle() async throws {
        try ScriptableObjectRegistry.register(
            LifecycleScript.self,
            identifier: "test.lifecycle",
            version: 1
        )
        let decoded = try JSONDecoder().decode(
            ScriptableComponents.self,
            from: Data("{\"scripts\":[{\"type\":\"test.lifecycle\",\"version\":1,\"payload\":{}}]}".utf8)
        )
        let script = try #require(decoded.scripts.first as? LifecycleScript)
        #expect(script.calls.isEmpty)

        let world = World(name: "Scriptable lifecycle")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.insertResource(DeltaTime(deltaTime: 0))
        let entity = world.spawn { decoded }

        let event = KeyEvent(
            window: RID(),
            keyCode: .space,
            modifiers: [],
            status: .down,
            time: 0,
            isRepeated: false
        )
        world.getRefResource(Input.self).wrappedValue.pendingEventsPool = [event]
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.update)
        await world.runScheduler(.postUpdate)

        #expect(script.calls.first == "ready")
        #expect(script.calls.contains("event"))
        #expect(script.calls.contains("update"))
        #expect(script.readyEntityID == entity.id)

        let fixedUpdateDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !script.calls.contains("fixedUpdate"), ContinuousClock.now < fixedUpdateDeadline {
            try await Task.sleep(for: .milliseconds(20))
            await world.runScheduler(.update)
        }
        #expect(script.calls.filter { $0 == "ready" }.count == 1)
        #expect(script.calls.contains("fixedUpdate"))

        world.remove(ScriptableComponents.self, from: entity.id)
        await world.runScheduler(.update)
        await world.runScheduler(.update)
        #expect(script.calls.filter { $0 == "destroy" }.count == 1)
    }
}

private final class LifecycleScript: ScriptableObject, @unchecked Sendable {
    var calls: [String] = []
    var readyEntityID: Entity.ID?

    override func ready(context: ScriptableObjectContext) {
        calls.append("ready")
        readyEntityID = context.entityID
    }

    override func update(context: ScriptableObjectContext) {
        calls.append("update")
    }

    override func fixedUpdate(context: ScriptableObjectContext) {
        calls.append("fixedUpdate")
    }

    override func event(_ events: [any InputEvent], context: ScriptableObjectContext) {
        calls.append("event")
    }

    override func destroy(context: ScriptableObjectContext) {
        calls.append("destroy")
    }
}
