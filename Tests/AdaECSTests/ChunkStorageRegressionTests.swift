@testable import AdaECS
import Testing

@Suite("Chunk storage regressions")
struct ChunkStorageRegressionTests {
    @Test("Removal updates both deleted and swapped locations")
    func removalUpdatesLocations() throws {
        var chunks = Chunks(entitiesPerChunk: 2, componentLayout: ComponentLayout(componentTypes: [ComponentA.self]))
        chunks.insertEntity(1, components: [ComponentA(value: 1)], tick: Tick(value: 1))
        chunks.insertEntity(2, components: [ComponentA(value: 2)], tick: Tick(value: 1))
        chunks.removeEntity(1)

        #expect(chunks.entities[1] == nil)
        #expect(chunks.entities.count == 1)
        #expect(chunks.entities[2]?.entityRow == 0)
        chunks.insert(ComponentA(value: 99), for: 2, lastTick: Tick(value: 2))
        #expect(chunks.chunks[0].get(ComponentA.self, for: 2)?.value == 99)
        #expect(chunks.removeEntity(1) == nil)
    }

    @Test("Delete followed by an archetype transition preserves surviving data")
    func deleteThenAddComponent() throws {
        let world = World()
        let entities = (0..<520).map { value in world.spawn { ComponentA(value: value) } }
        world.removeEntity(entities[0])

        // Chunk-local swap and archetype-global swap involve different entities.
        world.insert(ComponentB(value: "moved"), for: entities[249].id)
        #expect(world.get(ComponentA.self, from: entities[249].id)?.value == 249)
        #expect(world.get(ComponentB.self, from: entities[249].id)?.value == "moved")
        for index in 1..<entities.count {
            #expect(world.get(ComponentA.self, from: entities[index].id)?.value == index)
        }
        #expect(world.performQuery(Query<ComponentA>()).count == 519)
    }

    @Test("Column capacity is a slot count, independent of metatype representation")
    func columnCapacityIsSlotCount() throws {
        let capacity = 3
        let chunk = Chunk(entitiesPerChunk: capacity, layout: ComponentLayout(componentTypes: [ComponentA.self, ComponentB.self]))
        for type in [ComponentA.self as any Component.Type, ComponentB.self] {
            let column = try #require(chunk.componentsData[type.identifier])
            #expect(column.data.count == capacity)
            #expect(column.addedTicks.count == capacity)
            #expect(column.changeTicks.count == capacity)
            #expect(unsafe column.data.buffer.initialized.count == capacity)
        }
        let integers = try #require(chunk.componentsData[ComponentA.identifier])
        #expect(unsafe integers.data.buffer.pointer.count == capacity * MemoryLayout<ComponentA>.stride)
    }

    @Test("Repeated free-chunk lookup does not reserve slots")
    func repeatedLookupAndReuse() throws {
        let layout = ComponentLayout(components: [])
        var chunks = Chunks(entitiesPerChunk: 2, componentLayout: layout)
        for _ in 0..<10 { #expect(chunks.getFreeChunkIndex() == 0) }
        chunks.insertEntity(1, components: [], tick: Tick(value: 1))
        chunks.insertEntity(2, components: [], tick: Tick(value: 1))
        #expect(chunks.getFreeChunkIndex() == 1)
        chunks.removeEntity(1)
        #expect(chunks.getFreeChunkIndex() == 0)
        chunks.insertEntity(3, components: [], tick: Tick(value: 1))
        #expect(chunks.count == 2)
        #expect(chunks.entities[3]?.chunkIndex == 0)
    }

    @Test("Migration makes source capacity available again")
    func migrationReusesSourceChunk() {
        let layout = ComponentLayout(components: [])
        var source = Chunks(entitiesPerChunk: 2, componentLayout: layout)
        var destination = Chunks(entitiesPerChunk: 2, componentLayout: layout)
        source.insertEntity(1, components: [], tick: Tick(value: 1))
        source.insertEntity(2, components: [], tick: Tick(value: 1))
        #expect(source.getFreeChunkIndex() == 1)
        source.moveEntity(1, to: &destination)
        #expect(source.getFreeChunkIndex() == 0)
        source.insertEntity(3, components: [], tick: Tick(value: 1))
        #expect(source.entities[2]?.entityRow == 0)
        #expect(source.entities[3]?.entityRow == 1)
    }

    @Test("Clear resets free-chunk availability without allocating replacements")
    func clearReusesAllocatedChunks() {
        var chunks = Chunks(entitiesPerChunk: 2, componentLayout: ComponentLayout(components: []))
        for id in 1...6 { chunks.insertEntity(id, components: [], tick: Tick(value: 1)) }
        #expect(chunks.count == 3)
        chunks.removeEntity(2)
        chunks.clear()
        for id in 10...15 { chunks.insertEntity(id, components: [], tick: Tick(value: 2)) }
        #expect(chunks.count == 3)
        #expect(chunks.entities.count == 6)
        for id in 10...15 {
            #expect(chunks.entities[id] != nil)
        }
    }

    @Test("Public chunk replacement refreshes availability")
    func publicReplacementRefreshesAvailability() {
        let layout = ComponentLayout(components: [])
        var chunks = Chunks(entitiesPerChunk: 1, componentLayout: layout)
        chunks.insertEntity(1, components: [], tick: Tick(value: 1))
        #expect(chunks.getFreeChunkIndex() == 1)
        chunks[0] = Chunk(entitiesPerChunk: 1, layout: layout)
        #expect(chunks.getFreeChunkIndex() == 0)
    }

    @Test("Mixed deletion, migration and reinsertion keep locations consistent")
    func mixedStructuralChanges() throws {
        let layout = ComponentLayout(componentTypes: [ComponentA.self])
        var first = Chunks(entitiesPerChunk: 3, componentLayout: layout)
        var second = Chunks(entitiesPerChunk: 3, componentLayout: layout)
        for id in 1...30 { first.insertEntity(id, components: [ComponentA(value: id)], tick: Tick(value: 1)) }
        for id in stride(from: 1, through: 30, by: 3) { first.removeEntity(id) }
        for id in stride(from: 2, through: 30, by: 3) { _ = first.moveEntity(id, to: &second) }
        for id in 31...40 { first.insertEntity(id, components: [ComponentA(value: id)], tick: Tick(value: 2)) }

        for id in stride(from: 3, through: 30, by: 3) {
            let location = try #require(first.entities[id])
            #expect(first.chunks[location.chunkIndex].get(ComponentA.self, for: id)?.value == id)
        }
        for id in stride(from: 2, through: 30, by: 3) {
            let location = try #require(second.entities[id])
            #expect(second.chunks[location.chunkIndex].get(ComponentA.self, for: id)?.value == id)
        }
        for id in 31...40 {
            let location = try #require(first.entities[id])
            #expect(first.chunks[location.chunkIndex].get(ComponentA.self, for: id)?.value == id)
        }
        #expect(first.entities.count == 20)
        #expect(second.entities.count == 10)
    }
}
