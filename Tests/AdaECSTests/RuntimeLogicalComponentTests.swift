@_spi(Scripting) import AdaECS
import Testing

@Suite("Runtime logical components")
struct RuntimeLogicalComponentTests {
    @Test("Stores distinct logical schemas with one safe carrier type")
    @MainActor
    func storesAndQueriesDistinctSchemas() throws {
        let health = makeDescriptor(id: "tests.runtime.health", name: "RuntimeHealth", defaultValue: 3)
        let score = makeDescriptor(id: "tests.runtime.score", name: "RuntimeScore", defaultValue: 10)
        let world = World(name: "Runtime component world")
        world.registerRuntimeComponent(health)
        world.registerRuntimeComponent(score)

        let both = world.spawn("Both") {
            health.makeDefault()
            score.makeDefault()
        }
        _ = world.spawn("Health only") {
            health.makeDefault()
        }

        #expect(world.has(health.componentID, in: both.id))
        #expect(world.has(score.componentID, in: both.id))
        #expect(world.getRuntimeComponent(health.componentID, from: both.id)?.values == [.int(3)])
        #expect(world.getRuntimeComponent(score.componentID, from: both.id)?.values == [.int(10)])

        var access = SystemAccessSet()
        access.addComponentWrite(health.componentID)
        access.addComponentWrite(score.componentID)
        let query = DynamicQuery(
            where: .has(health.componentID) && .has(score.componentID),
            components: [health.componentID, score.componentID],
            access: access
        )
        query.update(from: world)
        let cursor = query.wrappedValue.makeCursor()
        #expect(cursor.advance())
        #expect(cursor.entityID == both.id)
        #expect(cursor.read(componentAt: 0, field: health.fields[0]) == .int(3))
        #expect(cursor.read(componentAt: 1, field: score.fields[0]) == .int(10))
        #expect(cursor.write(componentAt: 0, field: health.fields[0], value: .int(2)))
        #expect(!cursor.advance())
        #expect(world.getRuntimeComponent(health.componentID, from: both.id)?.values == [.int(2)])

        world.remove(score.componentID, from: both.id)
        #expect(world.has(health.componentID, in: both.id))
        #expect(!world.has(score.componentID, in: both.id))
        #expect(world.getRuntimeComponent(health.componentID, from: both.id)?.values == [.int(2)])
    }

    private func makeDescriptor(
        id: String,
        name: String,
        defaultValue: Int
    ) -> RuntimeComponentDescriptor {
        RuntimeComponentDescriptor(
            stableID: id,
            name: name,
            fields: [Self.valueField],
            defaultValues: [.int(defaultValue)]
        )
    }

    @safe
    private static let valueField = unsafe ReflectedComponentField(
        key: "value",
        label: "value",
        kind: .int,
        isWritable: true,
        accepts: { $0.intValue != nil },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let payload = unsafe pointer.assumingMemoryBound(to: RuntimeComponentPayload.self)
            return unsafe payload.pointee.values.first
        },
        writePointer: { pointer, value in
            guard let integer = value.intValue else {
                return false
            }
            let payload = unsafe pointer.assumingMemoryBound(to: RuntimeComponentPayload.self)
            unsafe payload.pointee.values[0] = .int(integer)
            return true
        }
    )
}
