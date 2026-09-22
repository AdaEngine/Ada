@_spi(Scripting) import AdaECS
import Testing

@Suite("Dynamic runtime query")
struct DynamicQueryTests {
    @Test("Binds component columns and mutates rows across chunks")
    @MainActor
    func iteratesAndWritesComponentColumns() throws {
        DynamicQueryPosition.registerComponent()

        let world = World(name: "Dynamic query test")
        var entities: [Entity] = []
        for index in 0..<260 {
            entities.append(
                world.spawn {
                    DynamicQueryPosition(value: index)
                }
            )
        }
        entities[17].isActive = false

        var access = SystemAccessSet()
        access.addComponentWrite(DynamicQueryPosition.self)
        let query = DynamicQuery(
            where: .has(DynamicQueryPosition.self),
            components: [DynamicQueryPosition.identifier],
            access: access
        )
        query.update(from: world)

        let descriptor = try #require(
            DynamicQueryPosition.componentDescriptor.fields.first { $0.key == "value" }
        )
        let cursor = query.wrappedValue.makeCursor()
        var visited = 0
        while cursor.advance() {
            let value = try #require(cursor.read(componentAt: 0, field: descriptor)?.intValue)
            #expect(cursor.write(componentAt: 0, field: descriptor, value: .int(value + 1)))
            visited += 1
        }

        #expect(visited == 259)
        #expect(world.get(DynamicQueryPosition.self, from: entities[0].id)?.value == 1)
        #expect(world.get(DynamicQueryPosition.self, from: entities[17].id)?.value == 17)
        #expect(world.get(DynamicQueryPosition.self, from: entities[259].id)?.value == 260)
    }
}

@Component
private struct DynamicQueryPosition {
    var value: Int
}
