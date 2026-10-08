//
//  Chunks.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2025.
//

import AdaUtils
import Foundation
import Logging
import OrderedCollections

// TODO: A lot of unsafe code. What we can do? Use Span?

public struct ChunkLocation: Sendable {
    public let chunkIndex: Int
    public let entityRow: Int
}

public struct MoveEntityResult: Sendable {
    public let newLocation: ChunkLocation
    public let swappedEntity: Entity.ID?
}

/// A chunk-based storage system for ECS components
/// Provides memory-efficient, cache-friendly storage for entities and their components
public struct Chunks: Sendable {
    /// Array of chunks for different archetypes
    public internal(set) var chunks: ContiguousArray<Chunk> = []

    /// Configuration for chunk storage
    public let entitiesPerChunk: Int

    private var friedLocation: [ChunkLocation] = []

    /// Location entity in chunk
    public private(set) var entities: SparseSet<Entity.ID, ChunkLocation> = [:]

    let componentLayout: ComponentLayout

    public var count: Int {
        chunks.count
    }

    public init(entitiesPerChunk: Int = 250, componentLayout: ComponentLayout) {
        self.entitiesPerChunk = entitiesPerChunk
        self.componentLayout = componentLayout
        self.chunks.append(Chunk(entitiesPerChunk: entitiesPerChunk, layout: componentLayout))
    }
}

extension Chunks {
    public mutating func getFreeChunkIndex() -> Int {
        if let firstLocation = friedLocation.popLast() {
            return firstLocation.chunkIndex
        } else if let possibleIndex = chunks.firstIndex(where: { !$0.isFull }) {
            return possibleIndex
        } else {
            let chunk = Chunk(entitiesPerChunk: entitiesPerChunk, layout: componentLayout)
            self.chunks.append(chunk)
            return self.chunks.endIndex - 1
        }
    }

    public func insert<T: Component>(
        _ component: T,
        for entity: Entity.ID,
        lastTick: Tick
    ) {
        guard let location = self.entities[entity] else {
            Logger(label: "org.adaengine.AdaECS.Chunk").error("Can't insert component \(T.self) for entity \(entity)")
            return
        }
        self.chunks[location.chunkIndex]
            .insert(
                component,
                at: location.entityRow,
                lastTick: lastTick
            )
    }

    public subscript(_ index: Int) -> Chunk {
        _read { yield chunks[index] }
        _modify { yield &chunks[index] }
    }

    @discardableResult
    public mutating func insertEntity(
        _ entity: Entity.ID,
        components: [any Component],
        tick: Tick
    ) -> ChunkLocation {
        let location = self.getFreeChunkIndex()
        var chunk = self.chunks[location]
        guard let entityLocation = chunk.addEntity(entity) else {
            fatalError("Failed to add entity \(entity) to chunk \(location)")
        }
        chunk.insert(at: entityLocation, components: components, tick: tick)
        let chunkLocation = ChunkLocation(
            chunkIndex: location,
            entityRow: entityLocation
        )
        self.entities[entity] = chunkLocation
        self.chunks[location] = chunk
        return chunkLocation
    }

    @discardableResult
    public mutating func removeEntity(_ entity: Entity.ID) -> MoveEntityResult? {
        guard let location = self.entities[entity] else {
            return nil
        }
        var chunk = self.chunks[location.chunkIndex]
        let swappedEntity = chunk.swapRemoveEntity(at: entity)
        self.chunks[location.chunkIndex] = chunk
        self.friedLocation.append(location)
        return MoveEntityResult(newLocation: location, swappedEntity: swappedEntity)
    }

    public mutating func moveEntity(_ entity: Entity.ID, to chunks: inout Chunks) -> MoveEntityResult {
        guard let location = self.entities[entity] else {
            fatalError("Entity \(entity) not found in chunks")
        }
        let oldChunk = self.chunks[location.chunkIndex]
        let newLocation = chunks.getFreeChunkIndex()
        var chunk = chunks.chunks[newLocation]
        let entityLocation = chunk.addEntity(entity)
            .unwrap(message: "Can't add entity to chunk")
        let chunkLocation = ChunkLocation(
            chunkIndex: newLocation,
            entityRow: entityLocation
        )
        chunks.entities[entity] = chunkLocation
        for component in chunks.componentLayout.components {
            guard
                let oldChunkComponent = oldChunk.componentsData[component.identifier],
                var newChunkComponent = chunk.componentsData[component.identifier]
            else {
                continue
            }

            oldChunkComponent.data
                .copyElement(
                    to: &newChunkComponent.data,
                    from: location.entityRow,
                    to: chunkLocation.entityRow
                )
            oldChunkComponent.addedTicks
                .copyElement(
                    to: &newChunkComponent.addedTicks,
                    from: location.entityRow,
                    to: chunkLocation.entityRow
                )
            oldChunkComponent.changeTicks
                .copyElement(
                    to: &newChunkComponent.changeTicks,
                    from: location.entityRow,
                    to: chunkLocation.entityRow
                )
            chunk.componentsData[component.identifier] = newChunkComponent
        }
        chunks.chunks[newLocation] = chunk
        // Don't deinitialize - data was copied to the new chunk (bitwise copy preserves references)
        let swappedEntity = self.swapRemoveEntity(entity, deinitialize: false)
        return MoveEntityResult(newLocation: chunkLocation, swappedEntity: swappedEntity)
    }

    @discardableResult
    private mutating func swapRemoveEntity(_ entity: Entity.ID, deinitialize: Bool = true) -> Entity.ID? {
        guard let location = self.entities[entity] else {
            return nil
        }

        var chunk = self.chunks[location.chunkIndex]
        let swappedEntityId = chunk.swapRemoveEntity(at: entity, deinitialize: deinitialize)
        self.entities.remove(for: entity)

        if let swappedEntityId {
            self.entities[swappedEntityId] = location
        }
        self.chunks[location.chunkIndex] = chunk

        return swappedEntityId
    }

    public mutating func clear() {
        for index in 0..<chunks.count {
            self.chunks[index].clear()
        }
        self.entities.removeAll()
        self.friedLocation.removeAll()
    }

    public func getComponentSlices<T: Component>(for type: T.Type) -> [UnsafeBufferPointer<T>] {
        var slices: [UnsafeBufferPointer<T>] = unsafe []
        for index in 0..<self.chunks.count {
            if let slice = unsafe self.chunks[index].getComponentSlice(for: type) {
                unsafe slices.append(slice)
            }
        }
        return unsafe slices
    }

    public func getComponentTicksSlices<T: Component>(
        for type: T.Type
    ) -> [ChangeTickSlices] {
        var slices: [ChangeTickSlices] = []
        for index in 0..<self.chunks.count {
            if let slice = self.chunks[index].getComponentTicksSlice(for: type) {
                slices.append(slice)
            }
        }
        return slices
    }
}

/// A memory-efficient chunk that stores entities and their components in contiguous memory
public struct Chunk: Sendable {
    public typealias RowIndex = Int

    @safe
    public struct ComponentsData: @unchecked Sendable, CustomStringConvertible {
        var data: BlobArray
        var addedTicks: BlobArray
        var changeTicks: BlobArray
        let componentType: any Component.Type

        init<T: Component>(capacity: Int, component: T.Type) {
            self.data = unsafe BlobArray(count: capacity, of: T.self) { pointer, count in
                // Deinitialize components that contain reference types to ensure proper cleanup
                guard !T.componentsInfo.isPlainOldData else {
                    return
                }
                unsafe pointer.baseAddress?
                    .assumingMemoryBound(to: T.self)
                    .deinitialize(count: count)
            }
            self.addedTicks = unsafe BlobArray(count: capacity, of: Tick.self)
            self.changeTicks = unsafe BlobArray(count: capacity, of: Tick.self)
            self.componentType = component
        }

        public var description: String {
            return """
                ComponentsData(
                    data: \(data.count),
                    addedTicks: \(addedTicks.count),
                    changeTicks: \(changeTicks.count),
                    componentType: \(componentType)
                )
                """
        }
    }

    @unsafe
    public struct ComponentData<T: Component> {
        public let component: UnsafeMutablePointer<T>
        public let addedTick: Tick
        public let changeTick: Tick
    }

    /// Maximum number of entities this chunk can hold
    public let entitiesPerChunk: Int

    /// Current number of entities in this chunk
    public private(set) var count: Int = 0

    /// Entity IDs stored in this chunk
    public private(set) var entities: ContiguousArray<Entity.ID>

    /// Map from entity ID to its index in the chunk
    public private(set) var entityIndices: [Entity.ID: RowIndex]

    /// Raw component data storage (organized by component type)
    public internal(set) var componentsData: SparseSet<ComponentId, ComponentsData>

    var currentIndex: Int {
        self.count
    }

    public var isEmpty: Bool {
        // swiftlint:disable:next empty_count
        self.count == 0
    }

    public var isFull: Bool {
        self.count == entitiesPerChunk
    }

    public init(entitiesPerChunk: Int, layout: ComponentLayout) {
        self.entitiesPerChunk = entitiesPerChunk
        self.entities = []
        self.entityIndices = [:]
        self.entityIndices.reserveCapacity(entitiesPerChunk)
        self.componentsData = [:]
        for component in layout.components {
            self.componentsData[component.identifier] = ComponentsData(
                capacity: entitiesPerChunk * MemoryLayout.stride(ofValue: component.componentType),
                component: component.componentType
            )
        }
    }

    /// Add an entity to this chunk
    /// - Parameter entityId: The entity identifier to add
    /// - Returns: The index where the entity was placed, or nil if chunk is full
    mutating func addEntity(_ entityId: Entity.ID) -> RowIndex? {
        if count >= entitiesPerChunk {
            assertionFailure("Chunk is full, cannot add entity \(entityId), self \(self.description)")
            return nil
        }

        if currentIndex < self.entities.count {
            self.entities[currentIndex] = entityId
        } else {
            self.entities.append(entityId)
        }

        let index = currentIndex
        entityIndices[entityId] = index
        count += 1

        return index
    }

    /// Remove an entity from this chunk
    /// - Parameter index: The index of the entity to remove
    mutating func removeEntity(at entityId: Entity.ID) {
        self.swapRemoveEntity(at: entityId)
    }

    mutating func clear() {
        self.componentsData.forEach { data in
            data.data.clear(entities.count)
            data.addedTicks.clear(entities.count)
            data.changeTicks.clear(entities.count)
        }
        self.entities.removeAll(keepingCapacity: true)
        self.entityIndices.removeAll(keepingCapacity: true)
        self.count = 0
    }

    /// Removes an entity from the chunk by swapping it with the last element.
    /// - Parameter entityId: The ID of the entity to remove.
    /// - Returns: The ID of the entity that was swapped into the removed entity's place, if any.
    @discardableResult
    mutating func swapRemoveEntity(at entityId: Entity.ID) -> Entity.ID? {
        return swapRemoveEntity(at: entityId, deinitialize: true)
    }

    /// Removes an entity from the chunk by swapping it with the last element.
    /// - Parameters:
    ///   - entityId: The ID of the entity to remove.
    ///   - deinitialize: Whether to deinitialize the removed component data.
    ///     Set to `false` when moving entities to another chunk (data is copied, not moved).
    /// - Returns: The ID of the entity that was swapped into the removed entity's place, if any.
    @discardableResult
    mutating func swapRemoveEntity(at entityId: Entity.ID, deinitialize: Bool) -> Entity.ID? {
        guard let removedIndex = self.entityIndices.removeValue(forKey: entityId) else {
            return nil
        }

        count -= 1
        let lastIndex = count

        if removedIndex < lastIndex {
            // Move component data from the last element to the removed element's slot
            for componentData in self.componentsData {
                componentData.data
                    .swapAndDrop(from: lastIndex, to: removedIndex, shouldDeinitialize: deinitialize)
                componentData.addedTicks
                    .swapAndDrop(from: lastIndex, to: removedIndex, shouldDeinitialize: false)
                componentData.changeTicks
                    .swapAndDrop(from: lastIndex, to: removedIndex, shouldDeinitialize: false)
            }

            // Update the entity that was in the last slot
            let swappedEntityId = self.entities[lastIndex]
            self.entities[removedIndex] = swappedEntityId
            self.entityIndices[swappedEntityId] = removedIndex
            self.entities.removeLast()

            return swappedEntityId
        } else {
            // The removed entity was the last one, so no swap is needed
            if deinitialize {
                // Deinitialize the component data for the removed entity
                for componentData in self.componentsData {
                    componentData.data.remove(at: removedIndex)
                    componentData.addedTicks.remove(at: removedIndex)
                    componentData.changeTicks.remove(at: removedIndex)
                }
            }
            self.entities.removeLast()

            return nil
        }
    }

    func insert(at entityIndex: RowIndex, components: [any Component], tick: Tick) {
        for component in components {
            let componentId = componentIdentifier(of: component)
            guard let array = componentsData[componentId] else {
                fatalError("Passed not registred component")
            }
            array.data.insert(component, at: entityIndex)
            array.addedTicks.insert(tick, at: entityIndex)
            array.changeTicks.insert(tick, at: entityIndex)
        }
    }

    @inline(__always)
    public func get<T: Component>(at entityIndex: RowIndex) -> T? {
        return self.componentsData[T.identifier]?.data.get(at: entityIndex, as: T.self)
    }

    public func isComponentChanged<T: Component>(
        _: T.Type,
        for entity: Entity.ID,
        lastTick: Tick
    ) -> Bool {
        guard let entityIndex = self.entityIndices[entity] else {
            return false
        }
        guard
            let lastChangeTick = self.componentsData[T.identifier]?
                .changeTicks
                .get(at: entityIndex, as: Tick.self)
        else {
            return false
        }

        return lastChangeTick >= lastTick
    }

    @inline(__always)
    public func get<T: Component>(_: T.Type, for entity: Entity.ID) -> T? {
        guard let index = self.entityIndices[entity] else {
            return nil
        }
        return self.componentsData[T.identifier]?
            .data
            .get(at: index, as: T.self)
    }

    @inline(__always)
    public func getMutablePointer<T: Component>(
        _: T.Type,
        for entity: Entity.ID
    ) -> UnsafeMutablePointer<T>? {
        guard let index = self.entityIndices[entity] else {
            return nil
        }
        return unsafe self.componentsData[T.identifier]?
            .data
            .getMutablePointer(at: index, as: T.self)
    }

    public func getMutableTick<T: Component>(
        _: T.Type,
        for entity: Entity.ID
    ) -> UnsafeMutablePointer<Tick>? {
        guard let index = self.entityIndices[entity] else {
            return nil
        }
        return unsafe self.componentsData[T.identifier]?
            .changeTicks
            .getMutablePointer(at: index, as: Tick.self)
    }

    public func insert<T: Component>(
        _ component: consuming T,
        at entityIndex: RowIndex,
        lastTick: Tick
    ) {
        guard let componentData = self.componentsData[T.identifier] else {
            assertionFailure("Component \(T.self) not found in chunk")
            return
        }
        componentData.changeTicks.insert(lastTick, at: entityIndex)
        componentData.data.insert(component, at: entityIndex)
    }

    /// Get all component data arrays for efficient iteration
    /// - Returns: Dictionary mapping component IDs to their data arrays
    public func getAllComponentData() -> SparseSet<ComponentId, ComponentsData> {
        return componentsData
    }

    public func getComponents(for entity: Entity.ID) -> [(ComponentId, any Component)] {
        guard let index = self.entityIndices[entity] else {
            return []
        }
        return componentsData.values.map { key, data in
            (key, data.data.get(at: index, as: data.componentType))
        }
    }

    func getRuntimeComponent(
        _ componentID: ComponentId,
        at entityIndex: RowIndex
    ) -> RuntimeComponentPayload? {
        componentsData[componentID]?.data.get(at: entityIndex, as: RuntimeComponentPayload.self)
    }

    func insertRuntimeComponent(
        _ component: consuming RuntimeComponentPayload,
        at entityIndex: RowIndex,
        lastTick: Tick
    ) {
        guard let componentData = componentsData[component.componentID] else {
            assertionFailure("Runtime component \(component.stableID) not found in chunk")
            return
        }
        componentData.changeTicks.insert(lastTick, at: entityIndex)
        componentData.data.insert(component, at: entityIndex)
    }

    public func getComponentSlice<T: Component>(for _: T.Type) -> UnsafeBufferPointer<T>? {
        guard let componentData = self.componentsData[T.identifier], !self.isEmpty else {
            return nil
        }
        let startPointer = unsafe componentData.data.getMutablePointer(at: 0, as: T.self)
        return unsafe UnsafeBufferPointer(start: startPointer, count: self.count)
    }

    public func getMutableComponentSlice<T: Component>(for _: T.Type) -> UnsafeMutablePointer<T>? {
        guard let componentData = self.componentsData[T.identifier], !self.isEmpty else {
            return nil
        }
        return unsafe componentData.data.getMutablePointer(at: 0, as: T.self)
    }

    public func getComponentTicksSlice<T: Component>(for _: T.Type) -> ChangeTickSlices? {
        guard let componentData = self.componentsData[T.identifier], !self.isEmpty else {
            return nil
        }
        return unsafe ChangeTickSlices(
            added: UnsafeBufferPointer(start: componentData.addedTicks.getMutablePointer(at: 0, as: Tick.self), count: self.count),
            changed: UnsafeBufferPointer(start: componentData.changeTicks.getMutablePointer(at: 0, as: Tick.self), count: self.count)
        )
    }

    public func getMutableComponentTicksSlice<T: Component>(for _: T.Type) -> ChangeMutableTickSlices? {
        guard let componentData = self.componentsData[T.identifier], !self.isEmpty else {
            return nil
        }
        return unsafe ChangeMutableTickSlices(
            added: componentData.addedTicks.getMutablePointer(at: 0, as: Tick.self),
            changed: componentData.changeTicks.getMutablePointer(at: 0, as: Tick.self)
        )
    }
}

@safe
public struct ChangeTickSlices {
    public let added: UnsafeBufferPointer<Tick>
    public let changed: UnsafeBufferPointer<Tick>
}

@safe
public struct ChangeMutableTickSlices {
    public let added: UnsafeMutablePointer<Tick>
    public let changed: UnsafeMutablePointer<Tick>
}

extension Chunk: CustomStringConvertible {
    public var description: String {
        return """
            Chunk(
                entitiesPerChunk: \(entitiesPerChunk),
                count: \(count),
                entities: \(entities.map(\.description)),
                entityIndices: \(entityIndices),
                componentsData:
                    \(componentsData.map(\.description).joined(separator: "\n"))
            )
            """
    }
}
