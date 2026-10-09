import AdaECS
import AdaUtils
import Synchronization
import Testing

struct BatchDynamicParent: Component {
    static let calls = SpawnSequence()
    static var requiredComponents: RequiredComponents {
        calls.next() % 2 == 1 ? RequiredComponents(components: [SpawnCacheChild.self]) : RequiredComponents(components: [])
    }
}

@Suite("Batch spawn")
struct BatchSpawnTests {
    @Test("Nonpositive counts do not invoke the builder or change the world")
    func emptyBatch() {
        let world = World()
        let calls = SpawnSequence()
        for count in [0, -1] {
            let batch = world.spawnBatch(count: count) { _ in
                SpawnCacheParent(value: calls.next())
            }
            #expect(batch.isEmpty)
        }
        // Invocation counter, not a collection.
        // swiftlint:disable:next empty_count
        #expect(calls.count == 0)
        #expect(world.getEntities().isEmpty)
    }

    @Test("Indexed values, names, IDs and locations span partially filled chunks")
    func valuesAndLocations() {
        let world = World()
        let original = (0..<17).map { index in world.spawn { ComponentA(value: -index) } }
        let batch = world.spawnBatch(count: 753, name: "Batch") { index in
            ComponentA(value: index)
            ComponentB(value: "\(index)")
        }
        #expect(batch.count == 753)
        #expect(Set(batch.map(\.id)).count == batch.count)
        for index in batch.indices {
            let entity = batch[index]
            #expect(entity.name == "Batch")
            #expect(entity.world === world)
            #expect(world.getEntityByID(entity.id) === entity)
            #expect(world.get(ComponentA.self, from: entity.id)?.value == index)
            #expect(world.get(ComponentB.self, from: entity.id)?.value == "\(index)")
        }
        for index in original.indices { #expect(world.get(ComponentA.self, from: original[index].id)?.value == -index) }
        #expect(world.getEntities().count == 770)
    }

    @Test("Batch fills holes in existing chunks and survives later migration")
    func reuseAndMigration() {
        let world = World()
        let original = (0..<520).map { index in world.spawn { ComponentA(value: index) } }
        for index in 0..<250 { world.removeEntity(original[index]) }
        let batch = world.spawnBatch(count: 513) { index in ComponentA(value: 1_000 + index) }
        world.insert(ComponentB(value: "moved"), for: batch[249].id)
        #expect(world.get(ComponentA.self, from: batch[249].id)?.value == 1_249)
        #expect(world.get(ComponentB.self, from: batch[249].id)?.value == "moved")
        for index in batch.indices { #expect(world.get(ComponentA.self, from: batch[index].id)?.value == 1_000 + index) }
        for index in 250..<520 { #expect(world.get(ComponentA.self, from: original[index].id)?.value == index) }
    }

    @Test("A common mask can contain different component orders and duplicate columns")
    func componentOrderAndDuplicates() {
        let world = World()
        let batch = world.spawnBatch(count: 520) { index in
            if index % 3 == 0 {
                ComponentA(value: -1)
                ComponentA(value: index)
                ComponentB(value: "\(index)")
            } else if index % 3 == 1 {
                ComponentB(value: "\(index)")
                ComponentA(value: index)
            } else {
                ComponentA(value: index)
                ComponentB(value: "\(index)")
            }
        }
        for index in batch.indices {
            #expect(world.get(ComponentA.self, from: batch[index].id)?.value == index)
            #expect(world.get(ComponentB.self, from: batch[index].id)?.value == "\(index)")
        }
    }

    @Test("Mixed layouts retain builder order and per-archetype values")
    func mixedLayouts() {
        let world = World()
        let batch = world.spawnBatch(count: 1_200) { index in
            ComponentA(value: index)
            if index % 2 == 1 { ComponentB(value: "odd") }
            if index % 3 == 0 { SpawnCacheOther(value: index) }
        }
        for index in batch.indices {
            #expect(world.get(ComponentA.self, from: batch[index].id)?.value == index)
            #expect(world.has(ComponentB.self, in: batch[index].id) == (index % 2 == 1))
            #expect(world.has(SpawnCacheOther.self, in: batch[index].id) == (index % 3 == 0))
        }
    }

    @Test("Registered factories are fresh and can change registration during preparation")
    func changingRequirements() {
        let world = World()
        let calls = SpawnSequence()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: calls.next()) }
        let batch = world.spawnBatch(count: 6) { index in
            if index == 3 {
                // Keep this side effect out of the result builder's component expressions.
                // swiftlint:disable:next redundant_discardable_let
                let _ = world.registerRequiredComponent(SpawnCacheOther.self, for: SpawnCacheParent.self) { SpawnCacheOther(value: 9) }
            }
            SpawnCacheParent(value: index)
        }
        for index in batch.indices {
            #expect(world.get(SpawnCacheChild.self, from: batch[index].id)?.value == index + 1)
            #expect(world.has(SpawnCacheOther.self, in: batch[index].id) == (index >= 3))
        }
        #expect(calls.count == 6)
        let defaults = world.spawnBatch(count: 3) { _ in SpawnCacheStaticParent() }
        for entity in defaults { #expect(world.get(SpawnCacheChild.self, from: entity.id)?.value == 43) }
    }

    @Test("Computed requirements can disappear from consecutive batch rows")
    func dynamicRequirements() {
        BatchDynamicParent.calls.reset()
        defer { BatchDynamicParent.calls.reset() }
        let world = World()
        let batch = world.spawnBatch(count: 520) { _ in BatchDynamicParent() }
        for index in batch.indices { #expect(world.has(SpawnCacheChild.self, in: batch[index].id) == (index % 2 == 0)) }
        #expect(BatchDynamicParent.calls.count == 520)
    }

    @Test("Logical runtime schemas share a carrier without mixing column values")
    func runtimeSchemas() {
        let world = World()
        let a = RuntimeComponentDescriptor(stableID: "tests.batch.a", name: "A", fieldNames: ["value"], defaultValues: [.int(3)])
        let b = RuntimeComponentDescriptor(stableID: "tests.batch.b", name: "B", fieldNames: ["value"], defaultValues: [.int(7)])
        let batch = world.spawnBatch(count: 520) { index in
            if index % 2 == 0 { a.makeDefault(); b.makeDefault() } else { b.makeDefault(); a.makeDefault() }
        }
        for entity in batch {
            #expect(world.getRuntimeComponent(a.componentID, from: entity.id)?.values == [.int(3)])
            #expect(world.getRuntimeComponent(b.componentID, from: entity.id)?.values == [.int(7)])
        }
    }

    @Test("Staging and column writes destroy each owned payload exactly once")
    func lifetime() {
        let world = World()
        let counter = DeinitCounter()
        let batch = world.spawnBatch(count: 520) { index in TrackableComponent(id: "\(index)", counter: counter) }
        #expect(counter.deinitializedIds.isEmpty)
        #expect(batch.count == 520)
        world.clear()
        #expect(counter.deinitializedIds.count == 520)
        #expect(Set(counter.deinitializedIds) == Set((0..<520).map(String.init)))
        let again = world.spawnBatch(count: 1) { _ in TrackableComponent(id: "again", counter: counter) }
        world.removeEntity(again[0])
        #expect(counter.deinitializedIds.count == 521)
    }

    @Test("Factories can spawn before IDs are allocated and observe no pending rows")
    func preparationVisibility() {
        let world = World()
        let calls = SpawnSequence()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) {
            let call = calls.next()
            if call == 1 { _ = world.spawn("Nested") { ComponentA(value: 99) } }
            #expect(world.getEntities().count == 1)
            return SpawnCacheChild(value: call)
        }
        let batch = world.spawnBatch(count: 4) { index in SpawnCacheParent(value: index) }
        #expect(batch.map(\.id) == Array(2...5))
        #expect(world.getEntities().count == 5)
    }

    @Test("Duplicate owned columns release overwritten and stored payloads once")
    func duplicateLifetime() {
        let world = World()
        let counter = DeinitCounter()
        let batch = world.spawnBatch(count: 260) { index in
            TrackableComponent(id: "discard-\(index)", counter: counter)
            TrackableComponent(id: "keep-\(index)", counter: counter)
        }
        #expect(counter.deinitializedIds.count == 260)
        #expect(Set(counter.deinitializedIds) == Set((0..<260).map { "discard-\($0)" }))
        for index in batch.indices { #expect(world.get(TrackableComponent.self, from: batch[index].id)?.id == "keep-\(index)") }
        world.clear()
        #expect(counter.deinitializedIds.count == 520)
        #expect(Set(counter.deinitializedIds).count == 520)
    }

    @Test("Reserving and appending batch metadata preserves existing snapshots")
    func metadataSnapshots() throws {
        let world = World()
        let original = world.spawn { ComponentA(value: -1) }
        let location = try #require(world.entities.entities[original.id])
        let snapshot = world.archetypes.archetypes
        let batch = world.spawnBatch(count: 520) { index in ComponentA(value: index) }
        #expect(snapshot[location.archetypeId].entities.map(\.id) == [original.id])
        #expect(snapshot[location.archetypeId].chunks.entities.count == 1)
        #expect(world.getEntities().count == batch.count + 1)
        #expect(world.get(ComponentA.self, from: original.id)?.value == -1)
    }

    @Test("Rows use one insertion tick after preparation finishes")
    func tickAfterPreparation() throws {
        let world = World()
        let batch = world.spawnBatch(count: 3) { index in
            // Keep the tick update out of component expressions.
            // swiftlint:disable:next redundant_discardable_let
            let _ = world.incrementChangeTick()
            ComponentA(value: index)
        }
        for entity in batch {
            let location = try #require(world.entities.entities[entity.id])
            let ticks = try #require(world.archetypes.archetypes[location.archetypeId].chunks[location.chunkIndex].getComponentTicksSlice(for: ComponentA.self))
            #expect(unsafe ticks.added[location.chunkRow] == world.currentTick)
        }
    }

    @Test("Events see the complete batch in index order and can spawn reentrantly")
    func eventsAndTicks() throws {
        let world = World()
        let observed = SpawnEventRecords()
        let tick = world.currentTick
        let subscription = world.subscribe(to: WorldEvents.DidAddEntity.self, on: world) { event in
            if event.entity.name == "Batch" {
                #expect(world.performQuery(Query<ComponentA>()).count == 520)
                let value = world.get(ComponentA.self, from: event.entity.id)?.value ?? -1
                observed.append(value)
                if value == 0 { _ = world.spawn("Nested") { SpawnCacheOther(value: 99) } }
            }
        }
        defer { subscription.cancel() }
        let batch = world.spawnBatch(count: 520, name: "Batch") { index in ComponentA(value: index) }
        #expect(observed.snapshot == Array(0..<520))
        #expect(world.getEntities().count == 521)
        for entity in batch {
            let location = try #require(world.entities.entities[entity.id])
            let ticks = try #require(world.archetypes.archetypes[location.archetypeId].chunks[location.chunkIndex].getComponentTicksSlice(for: ComponentA.self))
            #expect(unsafe ticks.added[location.chunkRow] == tick)
            #expect(unsafe ticks.changed[location.chunkRow] == tick)
        }
    }
}
