@testable import AdaECS
import Testing

@Suite("Component change journal")
struct ComponentChangeJournalTests {
    @Component
    struct Pose {
        var value: Int
    }

    @Component
    struct Unobserved {
        var value: Int
    }

    @Test func sameTickWritesAndMembershipChanges() throws {
        let world = World()
        let entity = world.spawn { Pose(value: 0) }
        let cursor = world.componentChanges.observe([Pose.identifier])
        let tick = world.currentTick
        _ = world.spawn { Unobserved(value: 1) }
        #expect(world.componentChanges.read(after: cursor).changes?.isEmpty == true)

        Query<Ref<Pose>>(from: world).forEach { $0.wrappedValue.value = 1 }
        world.insert(Pose(value: 2), for: entity.id)
        entity.components.remove(Pose.self)

        let changes = try #require(world.componentChanges.read(after: cursor).changes)
        #expect(world.currentTick == tick)
        #expect(changes.map(\.entity) == [entity.id, entity.id, entity.id])
        #expect(changes.map(\.component) == [Pose.identifier, Pose.identifier, nil])
    }

    @Test func anOverrunReaderCanResumeFromItsNewCursor() throws {
        let world = World()
        let entity = world.spawn { Pose(value: 0) }
        let cursor = world.componentChanges.observe([Pose.identifier])
        for value in 0..<32_769 { world.insert(Pose(value: value), for: entity.id) }
        let overrun = world.componentChanges.read(after: cursor)
        #expect(overrun.changes == nil)

        world.insert(Pose(value: -1), for: entity.id)
        let changes = try #require(world.componentChanges.read(after: overrun.cursor).changes)
        #expect(changes.map(\.entity) == [entity.id])
    }

    @Test func aliasedAndRawStorageUseTheFullReadFallback() throws {
        let world = World()
        let entity = world.spawn { Pose(value: 0) }
        let cursor = world.componentChanges.observe([Pose.identifier])
        let alias = world.copy()
        alias.insert(Pose(value: 1), for: entity.id)
        #expect(world.get(Pose.self, from: entity.id)?.value == 1)
        #expect(world.componentChanges.read(after: cursor).changes == nil)

        let rawWorld = World()
        let rawEntity = rawWorld.spawn { Pose(value: 0) }
        let rawCursor = rawWorld.componentChanges.observe([Pose.identifier])
        let location = try #require(rawWorld.entities.entities[rawEntity.id])
        let chunk = rawWorld.archetypes.archetypes[location.archetypeId].chunks.chunks[location.chunkIndex]
        chunk.insert(Pose(value: 2), at: location.chunkRow, lastTick: rawWorld.currentTick)
        #expect(rawWorld.get(Pose.self, from: rawEntity.id)?.value == 2)
        #expect(rawWorld.componentChanges.read(after: rawCursor).changes == nil)
    }
}
