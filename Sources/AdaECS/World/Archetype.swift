//
//  Archetype.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/21/22.
//

@_spi(Internal) import AdaUtils
import Atomics
import Foundation

/// The unique identifier of the component.
@frozen
public struct ComponentId: Hashable, Equatable, Sendable {
    /// The unique identifier of the component.
    @usableFromInline
    let id: Int
}

public struct EntityLocation: Sendable, Hashable {
    public let archetypeId: Archetype.ID
    public let archetypeRow: Int
    public let chunkIndex: Int
    public let chunkRow: Int
}

public struct ArchetypeSwapAndRemoveResult: Sendable {
    public let swappedEntity: Entity.ID?
    public let entityRow: Int
}

public final class Entities: @unchecked Sendable {
    public private(set) var entities: SparseSet<Entity.ID, EntityLocation> = [:]
    private let currentId = ManagedAtomic<Int>(1)
    let lock = NSRecursiveLock()

    func allocate(with name: String) -> Entity {
        let newId = currentId.loadThenWrappingIncrement(ordering: .relaxed)
        return Entity(name: name, id: newId)
    }

    func allocateBatch(count: Int, name: String) -> [Entity] {
        let firstID = currentId.loadThenWrappingIncrement(by: count, ordering: .relaxed)
        var result: [Entity] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            result.append(Entity(name: name, id: firstID &+ offset))
        }
        return result
    }

    func insertBatch(_ batch: [Entity], locations: [EntityLocation]) {
        lock.sync {
            entities.reserveCapacity(entities.count + batch.count)
            for index in batch.indices {
                entities[batch[index].id] = locations[index]
            }
        }
    }

    func addNotAllocatedEntity(_ entity: Entity) {
        guard entity.id == Entity.notAllocatedId else {
            return
        }
        let newId = currentId.loadThenWrappingIncrement(ordering: .relaxed)
        entity.id = newId
        entity.components.entity = newId
    }

    func insert(_ location: EntityLocation, for entity: Entity.ID) {
        lock.sync {
            entities[entity] = location
        }
    }

    func remove(_ entity: Entity.ID) {
        lock.sync {
            entities.remove(for: entity)
        }
    }

    func clear() {
        currentId.store(1, ordering: .relaxed)
        lock.sync {
            entities.removeAll(keepingCapacity: true)
        }
    }
}

public final class Archetypes: @unchecked Sendable {
    public var componentsIndex: [ComponentMaskSet: Archetype.ID]
    public var archetypes: ContiguousArray<Archetype>

    public init(
        componentsIndex _: [ComponentMaskSet: Archetype.ID] = [:],
        archetypes _: ContiguousArray<Archetype> = []
    ) {
        let emptyArchetype = Archetype.new(index: 0, componentLayout: ComponentLayout(components: []))
        self.componentsIndex = [ComponentMaskSet(): emptyArchetype.id]
        self.archetypes = [emptyArchetype]
    }

    public func getOrCreate(for componentLayout: ComponentLayout) -> Archetype.ID {
        if let archetypeIndex = self.componentsIndex[componentLayout.maskSet] {
            return archetypeIndex
        }

        let newIndex = archetypes.count
        let archetype = Archetype.new(index: newIndex, componentLayout: componentLayout)
        self.archetypes.append(archetype)
        componentsIndex[componentLayout.maskSet] = newIndex
        return newIndex
    }

    public func clear() {
        for index in 0..<self.archetypes.count {
            self.archetypes[index].clear()
        }
    }

    /// Borrows two distinct elements without making intermediate archetype copies.
    /// The closure must not resize or reenter this collection. Pointers stay within this scope.
    @inline(__always)
    @safe
    func withMutablePair<Result>(
        at firstIndex: Int,
        and secondIndex: Int,
        _ body: (inout Archetype, inout Archetype) -> Result
    ) -> Result {
        precondition(firstIndex != secondIndex, "Archetype mutation requires distinct indices")
        precondition(archetypes.indices.contains(firstIndex) && archetypes.indices.contains(secondIndex))
        // Swift cannot borrow two array subscripts simultaneously. Buffer access makes the
        // storage unique; checked, distinct indices give disjoint access for this nonescaping closure.
        return unsafe archetypes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = unsafe buffer.baseAddress else {
                preconditionFailure("Validated archetype indices require nonempty storage")
            }
            let first = unsafe baseAddress.advanced(by: firstIndex)
            let second = unsafe baseAddress.advanced(by: secondIndex)
            return unsafe body(&first.pointee, &second.pointee)
        }
    }
}

public struct ComponentLayout: Hashable, Sendable {
    public struct Entry: @unchecked Sendable {
        public let componentType: any Component.Type
        public let identifier: ComponentId

        init(componentType: any Component.Type, identifier: ComponentId) {
            self.componentType = componentType
            self.identifier = identifier
        }
    }

    public private(set) var components: [Entry]
    public private(set) var maskSet: ComponentMaskSet
    public var componentsSize: Int {
        components.reduce(0) { partialResult, entry in
            partialResult + MemoryLayout.size(ofValue: entry.componentType)
        }
    }

    public init(components: borrowing [any Component]) {
        var componentTypes: [Entry] = []
        var maskSet = ComponentMaskSet(reservingCapacity: components.count)
        components.forEach { component in
            let componentType = type(of: component)
            let identifier = componentIdentifier(of: component)
            componentTypes.append(Entry(componentType: componentType, identifier: identifier))
            maskSet.insert(identifier)
        }
        self.maskSet = maskSet
        self.components = componentTypes
    }

    public init(componentTypes: borrowing [any Component.Type]) {
        var set = ComponentMaskSet(reservingCapacity: componentTypes.count)
        componentTypes.forEach { component in
            set.insert(component.identifier)
        }
        self.maskSet = set
        self.components = componentTypes.map {
            Entry(componentType: $0, identifier: $0.identifier)
        }
    }

    public init<each T: Component>(components _: repeat each T) {
        var components: [Entry] = []
        var maskSet = ComponentMaskSet()
        for component in repeat (each T).self {
            let id = component.identifier
            components.append(Entry(componentType: component, identifier: id))
            maskSet.insert(id)
        }
        self.components = components
        self.maskSet = maskSet
    }

    public mutating func insert<T: Component>(_ component: T.Type) {
        self.maskSet.insert(component)
        self.components.append(Entry(componentType: component, identifier: component.identifier))
    }

    public mutating func insert(_ component: any Component.Type) {
        self.maskSet.insert(component)
        self.components.append(Entry(componentType: component, identifier: component.identifier))
    }

    public mutating func insert(runtime componentID: ComponentId) {
        self.maskSet.insert(componentID)
        self.components.append(Entry(componentType: RuntimeComponentPayload.self, identifier: componentID))
    }

    public mutating func remove(_ component: ComponentId) {
        self.maskSet.remove(component)
        self.components.removeAll { $0.identifier == component }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.maskSet == rhs.maskSet
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.maskSet)
    }
}

/// Types for defining Archetypes, collections of entities that have the same set of
/// components.
public struct Archetype: Identifiable, Sendable {
    /// The unique identifier of the archetype.
    public let id: Int

    public internal(set) var chunks: Chunks

    /// The entities in the archetype.
    public internal(set) var entities: ContiguousArray<Entity> = []

    /// The edge of the archetype.
    @usableFromInline
    var edges: Edges = Edges()

    /// The components bit mask of the archetype.
    public internal(set) var componentLayout: ComponentLayout

    /// Initialize a new archetype.
    /// - Parameter id: The unique identifier of the archetype.
    /// - Parameter entities: The entities in the archetype.
    private init(
        id: Self.ID,
        entities: [Entity] = [],
        componentLayout: ComponentLayout
    ) {
        self.id = id
        self.entities = ContiguousArray(entities)
        self.componentLayout = componentLayout
        self.chunks = Chunks(componentLayout: componentLayout)
    }
}

extension Archetype {
    mutating func reserveBatchCapacity(_ additionalCount: Int) {
        entities.reserveCapacity(entities.count + additionalCount)
        chunks.reserveBatchCapacity(additionalCount)
    }

    /// Checks if the archetype has any entities.
    public var isEmpty: Bool {
        self.entities.isEmpty
    }

    /// Create a new archetype.
    /// - Parameter index: The index of the archetype.
    /// - Returns: A new archetype.
    @inline(__always)
    public static func new(index: Int, componentLayout: ComponentLayout) -> Archetype {
        return Archetype(id: index, componentLayout: componentLayout)
    }

    /// Append an entity to the archetype.
    /// - Parameter entity: The entity to append.
    /// - Returns: The record of the entity.
    @inline(__always)
    public mutating func append(_ entity: consuming Entity) -> Int {
        self.entities.append(entity)
        return self.entities.count - 1
    }

    /// Remove an entity from the archetype.
    /// - Parameter index: The index of the entity to remove.
    @discardableResult
    @inline(__always)
    public mutating func swapRemove(at index: Int) -> ArchetypeSwapAndRemoveResult {
        let isLast = index == self.entities.count - 1
        _ = self.entities.swapRemove(at: index)

        return ArchetypeSwapAndRemoveResult(
            swappedEntity: isLast ? nil : self.entities[index].id,
            entityRow: index
        )
    }

    /// Clear the archetype.
    @inline(__always)
    public mutating func clear() {
        self.chunks.clear()
        self.entities.removeAll()
        self.edges = Edges()
    }
}

// MARK: - Hashable

extension Archetype: Hashable {
    /// Hash the archetype.
    /// - Parameter hasher: The hasher to hash the archetype.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(componentLayout)
        hasher.combine(entities)
    }

    /// Check if two archetypes are equal.
    /// - Parameter lhs: The left archetype.
    /// - Parameter rhs: The right archetype.
    /// - Returns: True if the two archetypes are equal, otherwise false.
    public static func == (lhs: Archetype, rhs: Archetype) -> Bool {
        return lhs.entities == rhs.entities && lhs.id == rhs.id && lhs.componentLayout == rhs.componentLayout
    }
}

extension Archetype: CustomStringConvertible {
    /// The description of the archetype.
    public var description: String {
        """
        Archetype(
            id: \(id)
            entityIds: \(entities.compactMap(\.id))
            componentsLayout: \(componentLayout)
        )
        """
    }
}

extension Archetype {
    /// The edges of the archetype.
    @usableFromInline
    struct Edges: Hashable, Sendable {
        /// The components to add.
        private var add: [ComponentLayout: Archetype.ID] = [:]

        /// The components to remove.
        private var remove: [ComponentLayout: Archetype.ID] = [:]

        @inline(__always)
        mutating func addArchetypeAfterInsertion(
            _ archetype: Archetype.ID,
            for layout: ComponentLayout
        ) {
            self.add[layout] = archetype
        }

        @inline(__always)
        mutating func addArchetypeAfterRemoval(
            _ archetype: Archetype.ID,
            for layout: ComponentLayout
        ) {
            self.remove[layout] = archetype
        }

        @inline(__always)
        func getArchetypeAfterInsertion(
            for layout: ComponentLayout
        ) -> Archetype.ID? {
            self.add[layout]
        }

        @inline(__always)
        func getArchetypeAfterRemoval(
            for layout: ComponentLayout
        ) -> Archetype.ID? {
            self.remove[layout]
        }
    }
}

public struct ComponentMaskSet: Hashable, Sendable {
    @usableFromInline
    var mask: Set<ComponentId>

    var isEmpty: Bool {
        return self.mask.isEmpty
    }

    @usableFromInline
    init(reservingCapacity: Int = 0) {
        self.mask = []
        self.mask.reserveCapacity(reservingCapacity)
    }

    @inlinable
    mutating func insert<T: Component>(_: T.Type) {
        self.mask.insert(T.identifier)
    }

    @inlinable
    mutating func insert(_ component: consuming ComponentId) {
        self.mask.insert(component)
    }

    @inlinable
    mutating func remove<T: Component>(_: T.Type) {
        self.mask.remove(T.identifier)
    }

    @inlinable
    mutating func remove(_ componentId: ComponentId) {
        self.mask.remove(componentId)
    }

    @inlinable
    public func contains(_ identifier: consuming ComponentId) -> Bool {
        self.mask.contains(identifier)
    }

    @inlinable
    func contains<T: Component>(_: T.Type) -> Bool {
        return self.mask.contains(T.identifier)
    }
}

extension Array where Element == any Component {
    var maskSet: ComponentMaskSet {
        var set = ComponentMaskSet(reservingCapacity: self.count)
        for component in self {
            set.insert(componentIdentifier(of: component))
        }
        return set
    }
}
