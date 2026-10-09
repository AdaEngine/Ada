//
//  ChunkTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.10.2025.
//

@testable import AdaECS
import Testing
import Foundation

// MARK: - Deinitialization Tracking Helpers

/// Thread-safe counter to track component deinitializations
final class DeinitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _deinitializedIds: [String] = []

    var deinitializedIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _deinitializedIds
    }

    func recordDeinit(id: String) {
        lock.lock()
        defer { lock.unlock() }
        _deinitializedIds.append(id)
    }
}

/// Tracker object that records its deinitialization
final class DeinitTracker: @unchecked Sendable, Equatable {
    let id: String
    let counter: DeinitCounter

    init(id: String, counter: DeinitCounter) {
        self.id = id
        self.counter = counter
    }

    deinit {
        counter.recordDeinit(id: id)
    }

    static func == (lhs: DeinitTracker, rhs: DeinitTracker) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Test Components

@Component
private struct A: Equatable {
    let a: Int
    let b: Bool
    let c: String

    init() {
        self.a = .random(in: 0..<100)
        self.b = .random()
        self.c =  UUID().uuidString
    }
}

@Component
private struct B: Equatable {
    let a: String
    let b: String
    let c: Bool
    let d: Int

    init() {
        self.a = UUID().uuidString
        self.b = UUID().uuidString
        self.c = .random()
        self.d = .random(in: 0..<100)
    }
}

/// Component that tracks deinitialization via a DeinitTracker
@Component
struct TrackableComponent: Equatable {
    let id: String
    let tracker: DeinitTracker

    init(id: String, counter: DeinitCounter) {
        self.id = id
        self.tracker = DeinitTracker(id: id, counter: counter)
    }
}

@Suite("Chunks Tests")
struct ChunksTests {
    var chunks: Chunks

    init() {
        self.chunks = Chunks(
            entitiesPerChunk: 32,
            componentLayout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )
    }

    @Test
    mutating func `inserted value returns correctly`() throws {
        let a = A()
        let b = B()
        let location = chunks.insertEntity(1, components: [a, b], tick: Tick(value: 0))

        #expect(chunks.entities.count == 1)
        #expect(chunks.chunks[location.chunkIndex].get(A.self, for: 1) == a)
        #expect(chunks.chunks[location.chunkIndex].get(B.self, for: 1) == b)
    }

    @Test
    mutating func `moves entities works correctly`() throws {
        let a = A()
        let b = B()
        chunks.insertEntity(1, components: [a, b], tick: Tick(value: 0))
        #expect(chunks.entities.count == 1)

        var newChunks = Chunks(
            entitiesPerChunk: 32,
            componentLayout: ComponentLayout(componentTypes: [A.self])
        )
        let newLocation = chunks.moveEntity(1, to: &newChunks)
        #expect(chunks.entities.count == 0)
        #expect(newChunks.entities.count == 1)
        #expect(newChunks.chunks[newLocation.newLocation.chunkIndex].count == 1)
        #expect(newChunks.chunks[newLocation.newLocation.chunkIndex].get(A.self, for: 1) == a)
        #expect(newChunks.chunks[newLocation.newLocation.chunkIndex].get(B.self, for: 1) == nil)
    }

    @Test
    mutating func `move entity to new chunk preserves components`() throws {
        // Scenario: Entity with component A moves to a chunk with [A, B] layout
        // Component A should be preserved in the new chunk
        
        let deinitCounter = DeinitCounter()
        
        // Create chunks with only TrackableComponent
        var sourceChunks = Chunks(
            entitiesPerChunk: 32,
            componentLayout: ComponentLayout(componentTypes: [TrackableComponent.self])
        )
        
        // Insert entity with TrackableComponent
        let entityId: Entity.ID = 42
        sourceChunks.insertEntity(
            entityId,
            components: [TrackableComponent(id: "PreservedComponent", counter: deinitCounter)],
            tick: Tick(value: 0)
        )
        
        #expect(sourceChunks.entities.count == 1)
        #expect(sourceChunks.chunks[0].get(TrackableComponent.self, for: entityId)?.id == "PreservedComponent")
        
        // Create destination chunks with [TrackableComponent, A] layout
        var destChunks = Chunks(
            entitiesPerChunk: 32,
            componentLayout: ComponentLayout(componentTypes: [TrackableComponent.self, A.self])
        )
        
        // Move entity to destination chunks
        let moveResult = sourceChunks.moveEntity(entityId, to: &destChunks)
        
        // Verify entity was removed from source
        #expect(sourceChunks.entities.count == 0)
        #expect(sourceChunks.chunks[0].count == 0)
        
        // Verify entity is in destination
        #expect(destChunks.entities.count == 1)
        #expect(destChunks.chunks[moveResult.newLocation.chunkIndex].count == 1)
        
        // Verify TrackableComponent was preserved (NOT deinitialized during move)
        #expect(!deinitCounter.deinitializedIds.contains("PreservedComponent"))
        
        // Verify the component data is still accessible and correct in the new chunk
        let movedComponent = destChunks.chunks[moveResult.newLocation.chunkIndex]
            .get(TrackableComponent.self, for: entityId)
        #expect(movedComponent?.id == "PreservedComponent")
    }

    @Test
    mutating func `remove entity in the first chunk`() throws {
        (0..<64).forEach { index in
            chunks.insertEntity(index, components: [A(), B()], tick: Tick(value: 0))
        }

        #expect(chunks.getFreeChunkIndex() == 2)
        #expect(chunks.count == 3)

        (0..<32).forEach { index in
            chunks.removeEntity(index)
        }

        #expect(chunks.count == 3)
        #expect(chunks.getFreeChunkIndex() == 0)

        (0..<32).forEach { index in
            chunks.insertEntity(index, components: [A(), B()], tick: Tick(value: 0))
        }

        #expect(chunks.count == 3)
        #expect(chunks.getFreeChunkIndex() == 2)
        #expect(chunks.chunks[0].entities.count == 32)
        #expect(chunks.chunks[1].entities.count == 32)
        #expect(chunks.chunks[2].entities.count == 0)
    }
}

@Suite("Chunk Tests")
struct ChunkTests {
    @Test
    func `inserted entity in chunk returns correctly`() throws {
        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )
        let a = A()
        let b = B()
        let rowId = chunk.addEntity(1)!
        chunk.insert(at: rowId, components: [a, b], tick: Tick(value: 0))
        #expect(chunk.count == 1)
        #expect(chunk.get(A.self, for: 1) == a)
        #expect(chunk.get(B.self, for: 1) == b)
    }

    @Test
    func `removed entity in chunk returns correctly`() throws {
        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )
        let rowId = chunk.addEntity(1)!
        chunk.insert(at: rowId, components: [A(), B()], tick: Tick(value: 0))
        chunk.removeEntity(at: 1)
        #expect(chunk.get(A.self, for: 1) == nil)
        #expect(chunk.get(B.self, for: 1) == nil)
        #expect(chunk.count == 0)
    }

    @Test
    func `updated components returns correctly`() throws {
        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )
        let a = A()
        let newA = A()
        let rowId = chunk.addEntity(1)!
        chunk.insert(at: rowId, components: [a, B()], tick: Tick(value: 0))
        #expect(a != newA)
        #expect(chunk.get(A.self, for: 1) == a)

        chunk.getMutablePointer(A.self, for: 1)?.pointee = newA
        #expect(chunk.get(A.self, for: 1) == newA)
    }
}

// MARK: Chunk Entities Manage

extension ChunkTests {
    @Test
    func `filled chunk correctly`() {
        let capacity = 128
        var chunk = Chunk(
            entitiesPerChunk: capacity,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )

        for index in 0..<capacity {
            let row = chunk.addEntity(index)!
            chunk.insert(at: row, components: [A(), B()], tick: Tick(value: 0))
        }
        #expect(chunk.count == capacity)
        #expect(chunk.isFull == true)
        #expect(chunk.entities.count == capacity)
    }

    @Test
    func `clear chunk works correctly`() {
        let capacity = 128
        var chunk = Chunk(
            entitiesPerChunk: capacity,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )

        for index in 0..<capacity {
            let row = chunk.addEntity(index)!
            chunk.insert(at: row, components: [A(), B()], tick: Tick(value: 0))
        }
        #expect(chunk.count == capacity)
        #expect(chunk.isFull == true)
        #expect(chunk.entities.count == capacity)

        chunk.clear()

        #expect(chunk.isFull == false)
        #expect(chunk.count == 0)
        #expect(chunk.entities.count == 0)
    }

    @Test
    func `remove entities in different places works correctly`() {
        let capacity = 128
        var chunk = Chunk(
            entitiesPerChunk: capacity,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )

        for index in 0..<capacity {
            let row = chunk.addEntity(index)!
            chunk.insert(at: row, components: [A(), B()], tick: Tick(value: 0))
        }
        #expect(chunk.count == capacity)
        #expect(chunk.isFull == true)
        #expect(chunk.entities.count == capacity)

        for index in 0..<capacity where index % 2 == 0 {
            chunk.removeEntity(at: index)
        }

        #expect(chunk.count == 64)
        #expect(chunk.isFull == false)
        #expect(chunk.entities.count == 64)
    }

    @Test
    func `swap remove entity deinitializes removed component and reorders correctly`() {
        // Counter to track deinitializations
        let deinitCounter = DeinitCounter()

        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [TrackableComponent.self]
            )
        )

        // Create 5 entities: A(0), B(1), C(2), D(3), E(4)
        let entityIds: [Entity.ID] = [0, 1, 2, 3, 4]
        let componentIds = ["A", "B", "C", "D", "E"]

        for (entityId, componentId) in zip(entityIds, componentIds) {
            let row = chunk.addEntity(entityId)!
            chunk.insert(
                at: row,
                components: [TrackableComponent(id: componentId, counter: deinitCounter)],
                tick: Tick(value: 0)
            )
        }

        #expect(chunk.count == 5)
        #expect(chunk.entities == [0, 1, 2, 3, 4])

        // Verify initial order
        #expect(chunk.get(TrackableComponent.self, for: 0)?.id == "A")
        #expect(chunk.get(TrackableComponent.self, for: 1)?.id == "B")
        #expect(chunk.get(TrackableComponent.self, for: 2)?.id == "C")
        #expect(chunk.get(TrackableComponent.self, for: 3)?.id == "D")
        #expect(chunk.get(TrackableComponent.self, for: 4)?.id == "E")

        // Remove entity B (id=1)
        // Expected: swap-remove should move E to B's position
        // Result: [A, E, C, D]
        let swappedEntity = chunk.swapRemoveEntity(at: 1)

        // Verify B was deinitialized
        #expect(deinitCounter.deinitializedIds.contains("B"))

        // Verify the swapped entity is E (last element)
        #expect(swappedEntity == 4)

        // Verify new count
        #expect(chunk.count == 4)
        #expect(chunk.entities.count == 4)

        // Verify new entity order: [A, E, C, D] (entity IDs: [0, 4, 2, 3])
        #expect(chunk.entities == [0, 4, 2, 3])

        // Verify component data is correctly reordered
        #expect(chunk.get(TrackableComponent.self, for: 0)?.id == "A")
        #expect(chunk.get(TrackableComponent.self, for: 4)?.id == "E") // E moved to B's slot
        #expect(chunk.get(TrackableComponent.self, for: 2)?.id == "C")
        #expect(chunk.get(TrackableComponent.self, for: 3)?.id == "D")

        // Entity B should no longer exist
        #expect(chunk.get(TrackableComponent.self, for: 1) == nil)
    }

    @Test
    func `remove single entity deinitializes its components`() {
        // Counter to track deinitializations
        let deinitCounter = DeinitCounter()

        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [TrackableComponent.self]
            )
        )

        // Create single entity
        let entityId: Entity.ID = 42
        let row = chunk.addEntity(entityId)!
        chunk.insert(
            at: row,
            components: [TrackableComponent(id: "SingleEntity", counter: deinitCounter)],
            tick: Tick(value: 0)
        )

        #expect(chunk.count == 1)
        #expect(chunk.entities == [42])
        #expect(chunk.get(TrackableComponent.self, for: 42)?.id == "SingleEntity")

        // Remove the only entity
        // This is an edge case: no swap needed since it's the last element
        let swappedEntity = chunk.swapRemoveEntity(at: entityId)

        // Verify the component was deinitialized
        #expect(deinitCounter.deinitializedIds.contains("SingleEntity"))

        // No entity was swapped since it was the only one
        #expect(swappedEntity == nil)

        // Verify chunk is empty
        #expect(chunk.count == 0)
        #expect(chunk.entities.isEmpty)

        // Entity should no longer exist
        #expect(chunk.get(TrackableComponent.self, for: 42) == nil)
    }

    @Test
    func `clear chunk deinitializes components`() {
        // Counter to track deinitializations
        let deinitCounter = DeinitCounter()

        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [TrackableComponent.self]
            )
        )

        // Create single entity
        let entityId: Entity.ID = 1
        let row = chunk.addEntity(entityId)!
        chunk.insert(
            at: row,
            components: [TrackableComponent(id: "TestComponent", counter: deinitCounter)],
            tick: Tick(value: 0)
        )

        #expect(chunk.count == 1)
        #expect(deinitCounter.deinitializedIds.isEmpty)

        // Clear the chunk - should deinitialize all components
        chunk.clear()

        // Verify the component was deinitialized
        #expect(deinitCounter.deinitializedIds.contains("TestComponent"))
        #expect(chunk.count == 0)
    }
}

// MARK: Ticks

extension ChunkTests {
    @Test
    func `set tick works correctly`() {
        var chunk = Chunk(
            entitiesPerChunk: 32,
            layout: ComponentLayout(
                componentTypes: [
                    A.self,
                    B.self
                ]
            )
        )

        let row = chunk.addEntity(1)!
        chunk.insert(at: row, components: [A(), B()], tick: Tick(value: 0))
        #expect(chunk.getMutableTick(A.self, for: 1)?.pointee == Tick(value: 0))

        let newA = A()
        chunk.insert(newA, at: row, lastTick: Tick(value: 2))

        #expect(chunk.getMutableTick(A.self, for: 1)?.pointee == Tick(value: 2))
        // The returned raw pointer borrows this chunk's allocation; its owner
        // must survive the pointee read even when this is its final use.
        withExtendedLifetime(chunk) {
            #expect(chunk.getMutablePointer(A.self, for: 1)?.pointee == newA)
        }
    }
}
