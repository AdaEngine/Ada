import AdaECS
import Testing

@Suite("Component ownership")
struct ComponentOwnershipTests {
    @Test("Native insertion preserves shared values across chunks and archetype moves")
    func nativeInsertion() throws {
        let world = World()
        world.registerRequiredComponent(ComponentA.self, for: ComponentB.self) {
            ComponentA(value: 42)
        }
        let entities = (0..<520).map { index in
            if index.isMultiple(of: 2) {
                return world.spawn { ComponentC() }
            }
            return world.spawn()
        }

        for (index, entity) in entities.enumerated() {
            let expected = String(repeating: "native-\(index)-", count: 8)
            var original = ComponentB(value: expected)
            world.insert(original, for: entity.id)
            original.value = "caller retains its own value"

            #expect(world.get(ComponentB.self, from: entity.id)?.value == expected)
            #expect(original.value == "caller retains its own value")
            #expect(world.get(ComponentA.self, from: entity.id)?.value == 42)

            let replacement = ComponentB(value: expected + "replacement")
            world.insert(consume replacement, for: entity.id)
            #expect(world.get(ComponentB.self, from: entity.id)?.value == expected + "replacement")
            #expect(world.has(ComponentC.self, in: entity.id) == index.isMultiple(of: 2))
        }

        for (index, entity) in entities.enumerated() {
            let stored = try #require(world.get(ComponentB.self, from: entity.id))
            #expect(stored.value == String(repeating: "native-\(index)-", count: 8) + "replacement")
        }
        #expect(world.performQuery(Query<ComponentB>()).count == entities.count)
    }

    @Test("Runtime insertion transfers payloads through direct and generic entry points")
    func runtimeInsertion() throws {
        let descriptor = RuntimeComponentDescriptor(
            stableID: "tests.ownership.payload",
            name: "OwnershipPayload",
            fieldNames: ["value"],
            defaultValues: [.int(0)]
        )
        let world = World()
        world.registerRuntimeComponent(descriptor)
        world.registerRequiredComponent(ComponentA.self, forRuntimeComponent: descriptor.componentID) {
            ComponentA(value: 42)
        }
        let entities = (0..<260).map { _ in world.spawn { ComponentC() } }

        for (index, entity) in entities.enumerated() {
            var original = descriptor.makeDefault()
            original.values = [.int(index)]
            if index.isMultiple(of: 2) {
                world.insertRuntimeComponent(original, for: entity.id)
            } else {
                world.insert(original, for: entity.id)
            }
            original.values[0] = .int(-1)
            #expect(world.getRuntimeComponent(descriptor.componentID, from: entity.id)?.values == [.int(index)])
            #expect(original.values == [.int(-1)])
            #expect(world.get(ComponentA.self, from: entity.id)?.value == 42)

            let replacement = RuntimeComponentPayload(
                componentID: descriptor.componentID,
                stableID: descriptor.stableID,
                values: [.int(index + 1000)]
            )
            if index.isMultiple(of: 2) {
                world.insert(consume replacement, for: entity.id)
            } else {
                world.insertRuntimeComponent(consume replacement, for: entity.id)
            }
        }

        for (index, entity) in entities.enumerated() {
            let stored = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity.id))
            #expect(stored.values == [.int(index + 1000)])
            #expect(world.has(ComponentC.self, in: entity.id))
        }
    }
}
