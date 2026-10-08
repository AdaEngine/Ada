@testable import AdaECS
import Testing

@Suite("Component lifetime")
struct ComponentLifetimeTests {
    @Test("Noncopyable blob values are destroyed once on replacement and clear")
    func noncopyableBlobLifetime() {
        let counter = DeinitCounter()
        let blob = unsafe BlobArray(count: 1, of: MoveOnlyTrackedValue.self) { pointer, count in
            unsafe pointer.baseAddress?.assumingMemoryBound(to: MoveOnlyTrackedValue.self).deinitialize(count: count)
        }
        blob.insert(MoveOnlyTrackedValue(tracker: DeinitTracker(id: "first", counter: counter)), at: 0)
        blob.insert(MoveOnlyTrackedValue(tracker: DeinitTracker(id: "second", counter: counter)), at: 0)
        #expect(counter.deinitializedIds == ["first"])
        blob.clear(1)
        #expect(counter.deinitializedIds.sorted() == ["first", "second"])
    }

    @Test("Blob growth and shrink preserve initialized slots and release removed values")
    func blobReallocationPreservesLifetime() {
        let counter = DeinitCounter()
        var blob = unsafe BlobArray(count: 2, of: TrackableComponent.self) { pointer, count in
            unsafe pointer.baseAddress?.assumingMemoryBound(to: TrackableComponent.self).deinitialize(count: count)
        }
        blob.insert(TrackableComponent(id: "kept", counter: counter), at: 0)
        blob.insert(TrackableComponent(id: "truncated", counter: counter), at: 1)
        blob.realloc(4)
        #expect(counter.deinitializedIds.isEmpty)
        blob.realloc(1)
        #expect(counter.deinitializedIds == ["truncated"])
        blob.insert(TrackableComponent(id: "replacement", counter: counter), at: 0)
        #expect(counter.deinitializedIds.sorted() == ["kept", "truncated"])
        blob.clear(1)
        #expect(counter.deinitializedIds.sorted() == ["kept", "replacement", "truncated"])
    }

    @Test("Public chunk insertion fills new columns after a layout transition")
    func publicInsertionInitializesNewColumns() throws {
        let counter = DeinitCounter()
        var source = Chunks(componentLayout: ComponentLayout(componentTypes: [ComponentA.self]))
        source.insertEntity(1, components: [ComponentA(value: 7)], tick: Tick(value: 3))
        var destination = Chunks(componentLayout: ComponentLayout(componentTypes: [ComponentA.self, TrackableComponent.self]))
        let location = source.moveEntity(1, to: &destination).newLocation

        destination.insert(TrackableComponent(id: "first", counter: counter), for: 1, lastTick: Tick(value: 5))
        destination.insert(TrackableComponent(id: "second", counter: counter), for: 1, lastTick: Tick(value: 9))

        let chunk = destination.chunks[location.chunkIndex]
        #expect(chunk.get(TrackableComponent.self, for: 1)?.id == "second")
        let ticks = try #require(chunk.getComponentTicksSlice(for: TrackableComponent.self))
        #expect(unsafe ticks.added[location.entityRow] == Tick(value: 5))
        #expect(unsafe ticks.changed[location.entityRow] == Tick(value: 9))
        #expect(counter.deinitializedIds == ["first"])
        destination.clear()
        #expect(counter.deinitializedIds.sorted() == ["first", "second"])
    }

    @Test("Clearing partial destination columns does not destroy uninitialized values")
    func clearingPartialColumns() {
        let counter = DeinitCounter()
        var source = Chunks(componentLayout: ComponentLayout(componentTypes: [TrackableComponent.self]))
        source.insertEntity(1, components: [TrackableComponent(id: "moved", counter: counter)], tick: Tick(value: 1))
        var destination = Chunks(componentLayout: ComponentLayout(componentTypes: [TrackableComponent.self, OtherTrackedComponent.self]))
        source.moveEntity(1, to: &destination)
        source.clear()
        #expect(counter.deinitializedIds.isEmpty)
        destination.clear()
        #expect(counter.deinitializedIds == ["moved"])
    }

    @Test("Removing an absent component leaves the entity and its location unchanged")
    func removingAbsentComponentIsNoOp() throws {
        let world = World()
        let entity = world.spawn { ComponentA(value: 7) }
        let location = try #require(world.entities.entities[entity.id])

        world.remove(ComponentB.self, from: entity.id)

        #expect(world.entities.entities[entity.id] == location)
        #expect(world.get(ComponentA.self, from: entity.id)?.value == 7)
        #expect(world.performQuery(Query<ComponentA>()).count == 1)
    }

    @Test("Archetype metadata snapshots survive in-place transitions")
    func archetypeSnapshotsRemainIndependent() throws {
        let world = World()
        let first = world.spawn { ComponentA(value: 1) }
        let second = world.spawn { ComponentA(value: 2) }
        let location = try #require(world.entities.entities[first.id])
        let snapshot = world.archetypes.archetypes

        world.insert(ComponentB(value: "new column"), for: first.id)

        #expect(snapshot[location.archetypeId].entities.map(\.id) == [first.id, second.id])
        #expect(snapshot[location.archetypeId].chunks.entities.count == 2)
        #expect(world.archetypes.archetypes[location.archetypeId].entities.map(\.id) == [second.id])
        #expect(world.get(ComponentA.self, from: first.id)?.value == 1)
        #expect(world.get(ComponentB.self, from: first.id)?.value == "new column")
    }

    @Test("New runtime columns initialize added ticks and replacement preserves them")
    func runtimeColumnTicks() throws {
        let descriptor = RuntimeComponentDescriptor(
            stableID: "tests.lifetime.runtime",
            name: "LifetimeRuntime",
            fieldNames: ["value"],
            defaultValues: [.int(1)]
        )
        let world = World()
        world.registerRuntimeComponent(descriptor)
        let entity = world.spawn()
        world.insertRuntimeComponent(descriptor.makeDefault(), for: entity.id)
        let location = try #require(world.entities.entities[entity.id])
        let data = try #require(
            world.archetypes.archetypes[location.archetypeId].chunks.chunks[location.chunkIndex]
                .componentsData[descriptor.componentID]
        )
        #expect(data.addedTicks.get(at: location.chunkRow, as: Tick.self) == world.currentTick)

        let replacement = RuntimeComponentPayload(componentID: descriptor.componentID, stableID: descriptor.stableID, values: [.int(2)])
        world.archetypes.archetypes[location.archetypeId].chunks.chunks[location.chunkIndex]
            .insertRuntimeComponent(consume replacement, at: location.chunkRow, lastTick: Tick(value: 23))

        #expect(data.addedTicks.get(at: location.chunkRow, as: Tick.self) == world.currentTick)
        #expect(data.changeTicks.get(at: location.chunkRow, as: Tick.self) == Tick(value: 23))
        #expect(world.getRuntimeComponent(descriptor.componentID, from: entity.id)?.values == [.int(2)])
    }

    @Test("Moving to a smaller archetype releases only removed components")
    func removalReleasesOnlyRemovedComponents() {
        let counter = DeinitCounter()
        let world = World()
        let entity = world.spawn {
            TrackableComponent(id: "preserved", counter: counter)
            OtherTrackedComponent(tracker: DeinitTracker(id: "removed", counter: counter))
        }

        world.remove(OtherTrackedComponent.self, from: entity.id)
        #expect(counter.deinitializedIds == ["removed"])
        #expect(world.get(TrackableComponent.self, from: entity.id)?.id == "preserved")

        world.removeEntity(entity)
        #expect(counter.deinitializedIds.sorted() == ["preserved", "removed"])
    }

    @Test("Replacing a component releases its previous value exactly once")
    func replacementReleasesPreviousValue() {
        let counter = DeinitCounter()
        let world = World()
        let entity = world.spawn {
            TrackableComponent(id: "old", counter: counter)
        }

        world.insert(TrackableComponent(id: "new", counter: counter), for: entity.id)
        #expect(counter.deinitializedIds == ["old"])
        #expect(world.get(TrackableComponent.self, from: entity.id)?.id == "new")

        world.removeEntity(entity)
        #expect(counter.deinitializedIds.sorted() == ["new", "old"])
    }

    @Test("Chunk replacement preserves the added tick and updates the changed tick")
    func chunkReplacementPreservesAddedTick() throws {
        let counter = DeinitCounter()
        var chunks = Chunks(componentLayout: ComponentLayout(componentTypes: [TrackableComponent.self]))
        let location = chunks.insertEntity(
            1,
            components: [TrackableComponent(id: "old", counter: counter)],
            tick: Tick(value: 5)
        )
        chunks.insert(TrackableComponent(id: "new", counter: counter), for: 1, lastTick: Tick(value: 23))
        let ticks = try #require(chunks.chunks[location.chunkIndex].getComponentTicksSlice(for: TrackableComponent.self))
        #expect(unsafe ticks.added[location.entityRow] == Tick(value: 5))
        #expect(unsafe ticks.changed[location.entityRow] == Tick(value: 23))
        #expect(counter.deinitializedIds == ["old"])

        chunks.clear()
        #expect(counter.deinitializedIds.sorted() == ["new", "old"])
    }
}

private struct OtherTrackedComponent: Component {
    let tracker: DeinitTracker
}

private struct MoveOnlyTrackedValue: ~Copyable {
    let tracker: DeinitTracker
}
