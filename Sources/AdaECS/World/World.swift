//
//  World.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/26/22.
//

import AdaUtils
import Atomics
import Collections
import Foundation
import Tracing

/// World syncronization actor.
@globalActor
public actor WorldActor {
    public static let shared = WorldActor()
}

/// Stores and exposes operations on ``Entity`` and ``Component``.
///
/// Each ``Entity`` has a set of components. Each component can have up to one instance of each
/// component type. Entity components can be created, updated, removed, and queried using a given World.
/// - Warning: Still work in progress.
public final class World: @unchecked Sendable, Codable {
    /// The unique identifier of the world.
    public typealias ID = RID

    /// The unique identifier of the world.
    public let id = ID()
    public let name: String?

    public private(set) var changeTick = ManagedAtomic<Int>(1)
    public private(set) var lastTick: Tick = Tick(value: 0)

    public var currentTick: Tick {
        Tick(value: changeTick.load(ordering: .acquiring))
    }

    /// The archetypes of the world.
    public private(set) var entities: Entities = Entities()
    public private(set) var archetypes: Archetypes = Archetypes()

    /// The removed entities of the world.
    internal private(set) var removedEntities: Set<Entity.ID> = []
    /// The added entities of the world.
    internal private(set) var addedEntities: Set<Entity.ID> = []
    /// The updated entities of the world.
    private var removedComponents: [Entity.ID: Set<ComponentId>] = [:]

    private var componentsStorage = ComponentsStorage()
    public var commandQueue: WorldCommandQueue = WorldCommandQueue()

    var resources = Resources()

    public private(set) var eventManager: EventManager = EventManager.default

    // Scheduler registry and mapping from scheduler to systems
    public let schedulers = Schedulers(SchedulerName.default)

    // MARK: - Methods

    public init(name: String? = nil) {
        self.name = name
    }

    private init(from world: borrowing World) {
        self.name = world.name
        self.archetypes = world.archetypes
        self.entities = world.entities
        self.componentsStorage = world.componentsStorage
    }

    /// Initialize a new world from a decoder.
    /// - Parameter decoder: The decoder to initialize the world from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        let entities = try container.decode([Entity].self, forKey: .entities)

        for entity in entities {
            self.addEntity(entity)
        }

        let resourcesContainer = try container.nestedContainer(keyedBy: CodingName.self, forKey: .resources)
        for resourceKey in resourcesContainer.allKeys {
            guard let resourceType = ResourceStorage.getRegisteredResource(for: resourceKey.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resources,
                    in: container,
                    debugDescription: "Resource \(resourceKey) not found"
                )
            }

            if let decodable = resourceType as? Decodable.Type {
                let resource = try decodable.init(from: resourcesContainer.superDecoder(forKey: resourceKey))
                self.insertTypeErasedResource(resource as! Resource)
            }
        }

        self.flush()
    }

    /// Encode the world to an encoder.
    /// - Parameter encoder: The encoder to encode the world to.
    public func encode(to encoder: Encoder) throws {
        self.flush()

        var container = encoder.container(keyedBy: CodingKeys.self)
        let entities = self.getEntities()
            .sorted(by: {
                $0.id < $1.id
            })
        try container.encode(entities, forKey: .entities)
        var unkeyedContainer = container.nestedContainer(keyedBy: CodingName.self, forKey: .resources)
        for resource in self.resources.getResources() {
            try unkeyedContainer.encode(AnyEncodable(resource), forKey: CodingName(stringValue: type(of: resource).swiftName))
        }
    }

    public func copy() -> World {
        World(from: self)
    }
}

// MARK: - Scheduler API

extension World {
    /// Set the order of schedulers for this world.
    /// - Parameter schedulers: The schedulers to set.
    public func setSchedulers(_ schedulers: [SchedulerName]) {
        self.schedulers.setSchedulers(schedulers)
    }

    /// Insert a scheduler before or after another scheduler.
    /// - Parameter scheduler: The scheduler to insert.
    /// - Parameter after: The scheduler after which to insert the new scheduler.
    public func insertScheduler(_ scheduler: Scheduler, after: SchedulerName) {
        schedulers.insert(scheduler, after: after)
    }

    /// Insert a scheduler before or before another scheduler.
    /// - Parameter scheduler: The scheduler to insert.
    /// - Parameter before: The scheduler before which to insert the new scheduler.
    public func insertScheduler(_ scheduler: Scheduler, before: SchedulerName) {
        schedulers.insert(scheduler, before: before)
    }

    /// Contains scheduler
    /// - Parameter scheduler: The scheduler to check.
    /// - Returns: True if the scheduler exists, otherwise false.
    public func containsScheduler(_ scheduler: SchedulerName) -> Bool {
        self.schedulers.contains(scheduler)
    }

    /// Add schedulers.
    /// - Parameter schedulers: The schedulers to add.
    public func addSchedulers(_ schedulers: SchedulerName...) {
        schedulers.forEach {
            self.schedulers.append(Scheduler(name: $0))
        }
    }

    /// Add scheduler
    /// - Parameter scheduler: The scheduler to add.
    public func addScheduler(_ scheduler: Scheduler) {
        self.schedulers.append(scheduler)
    }

    /// Run a specific scheduler.
    /// - Parameter scheduler: Scheduler name.
    /// - Parameter deltaTime: Time interval since last update.
    public func runScheduler(_ schedulerName: SchedulerName) async {
        await AdaTrace.span(
            lazyName: "World.runScheduler.\(schedulerName.rawValue)",
            attributes: [
                "ada.profile.category": "scheduler",
                "ada.scheduler.name": .string(schedulerName.rawValue),
                "ada.world.name": .string(self.name ?? "UnknownWorld"),
            ]
        ) {
            await self.schedulers.getScope(for: schedulerName) {
                await $0.run(world: self)
            }
        }
    }
}

// MARK: - Systems API

extension World {
    /// Add new system to the world.
    /// - Parameter systemType: System type.
    /// Add a system to a specific scheduler.
    @discardableResult
    public func addSystem<T: System>(_ systemType: T.Type, on scheduler: SchedulerName = .update) -> Self {
        let system = systemType.init(world: self)
        self.schedulers.addSystem(
            system,
            for: scheduler
        )
        return self
    }

    /// Remove a system from the world.
    /// - Parameter systemType: System type.
    /// - Parameter scheduler: The scheduler to remove the system from.
    @discardableResult
    public func removeSystem<T: System>(_ systemType: T.Type, on scheduler: SchedulerName = .update) -> Self {
        self.schedulers.removeSystem(systemType, for: scheduler)
        return self
    }
}

// MARK: - Entities managment

extension World {
    /// Get all entities in world.
    /// - Complexity: O(n)
    /// - Returns: All entities in world.
    public func getEntities() -> [Entity] {
        return self.entities.entities
            .compactMap { location in
                let archetype = self.archetypes.archetypes[location.archetypeId]
                return archetype.entities[location.archetypeRow]
            }
    }

    /// Get an entity by their id.
    /// - Parameter id: Entity identifier.
    /// - Complexity: O(1)
    /// - Returns: Returns nil if entity not registed in scene world.
    public func getEntityByID(_ entityID: Entity.ID) -> Entity? {
        guard let location = self.entities.entities[entityID] else {
            return nil
        }

        return self.archetypes
            .archetypes[location.archetypeId]
            .entities[location.archetypeRow]
    }

    /// Find an entity by name.
    /// - Note: Not efficient way to find an entity.
    /// - Complexity: O(n)
    /// - Returns: An entity with matched name or nil if entity with given name not exists.
    public func getEntityByName(_ name: String) -> Entity? {
        for arch in archetypes.archetypes {
            if let ent = arch.entities.first(where: { $0.name == name }) {
                return ent
            }
        }

        return nil
    }

    /// Add a new entity to the world.
    /// - Parameter entity: The entity to add.
    /// - Returns: A world instance.
    @discardableResult
    public func addEntity(_ entity: consuming Entity) -> Self {
        self.flush()

        if entity.id == Entity.notAllocatedId {
            entities.addNotAllocatedEntity(entity)
        }

        insertNewEntity(
            entity,
            components: Array(entity.components.notFlushedComponents)
        )
        return self
    }

    /// Remove entity from world.
    /// - Parameter recursively: also remove entity child.
    /// - Returns: A world instance.
    @discardableResult
    public func removeEntity(_ entity: borrowing Entity, recursively: Bool = false) -> Self {
        // Read the hierarchy while its component storage still exists.
        let children = recursively ? entity.children : []
        self.removeEntityRecord(entity.id)

        for child in children {
            self.removeEntity(child, recursively: true)
        }

        return self
    }

    /// Remove entity by id from world.
    /// - Parameter recursively: also remove entity child.
    /// - Returns: A world instance.
    @discardableResult
    public func removeEntity(_ entity: borrowing Entity.ID, recursively: Bool = false) -> Self {
        guard let entity = self.getEntityByID(entity) else {
            return self
        }

        return self.removeEntity(entity, recursively: recursively)
    }

    /// Remove entity from world.
    /// - Note: Entity will removed on next `update` call.
    /// - Parameter recursively: also remove entity child.
    public func removeEntityOnNextTick(_ entity: consuming Entity, recursively: Bool = false) {
        guard self.entities.entities[entity.id] != nil else {
            return
        }

        let entity = entity
        defer { eventManager.send(WorldEvents.WillRemoveEntity(entity: entity), source: self) }
        self.removedEntities.insert(entity.id)

        guard recursively && !entity.children.isEmpty else {
            return
        }

        for child in entity.children {
            self.removeEntityOnNextTick(child, recursively: recursively)
        }
    }
}

// MARK: - World utils

extension World {
    public func makeCommands() -> Commands {
        Commands(entities: entities, commandsQueue: self.commandQueue.copy())
    }

    public func flushCommands() {
        guard !commandQueue.isEmpty else {
            return
        }
        self.commandQueue.applyAndDrop(to: self)
    }

    /// Update all data in world.
    /// In this step we move entities to matched archetypes and remove pending in delition entities.
    public func flush() {
        self.flushCommands()

        for entityId in self.removedEntities {
            self.removeEntityRecord(entityId)
        }
    }

    /// Clear trackers for entities, components and resources.
    /// - Complexity: O(1)
    public func clearTrackers() {
        self.removedEntities.removeAll(keepingCapacity: true)
        self.addedEntities.removeAll(keepingCapacity: true)
        self.lastTick = self.incrementChangeTick()
    }

    /// Remove all data from world exclude resources.
    /// - Complexity: O(n)
    public func clear() {
        self.entities.clear()
        self.archetypes.clear()
        self.removedEntities.removeAll(keepingCapacity: true)
        self.addedEntities.removeAll(keepingCapacity: true)
        self.commandQueue = WorldCommandQueue()
    }

    public func incrementChangeTick() -> Tick {
        let lastValue = self.changeTick.loadThenWrappingIncrement(
            ordering: .relaxed
        )
        return Tick(value: lastValue)
    }
}

// MARK: - Resource API

extension World {
    /// Insert a resource into the world.
    /// - Parameter resource: The resource to insert.
    /// - Returns: A world instance.
    @discardableResult
    public func insertResource<T: Resource>(_ resource: consuming T) -> Self {
        self.resources.insertResource(resource, tick: currentTick)
        return self
    }

    /// Insert a resource into the world.
    /// - Parameter resource: The resource to insert.
    /// - Returns: A world instance.
    @discardableResult
    private func insertTypeErasedResource(_ resource: consuming any Resource) -> Self {
        self.resources.insertResource(resource, tick: currentTick)
        return self
    }

    /// Create a resource from world.
    /// - Parameter type: The resource type.
    /// - Returns: A resource instance.
    public func createResource<T: Resource & WorldInitable>(of type: T.Type) -> T {
        let resource = type.init(from: self)
        self.resources.insertResource(resource, tick: currentTick)
        return resource
    }

    /// Create a resource from world.
    /// - Parameter type: The resource type.
    /// - Returns: A resource instance.
    @inlinable
    @discardableResult
    public func initResource<T: Resource & WorldInitable>(_ type: T.Type) -> Self {
        _ = self.createResource(of: type)
        return self
    }

    /// Remove a resource from the world.
    /// - Parameter resource: The resource to remove.
    public consuming func removeResource<T: Resource>(_ resource: T.Type) {
        self.resources.removeResource(resource)
    }

    /// Get a resource from the world.
    /// - Parameter resource: The resource to get.
    /// - Complexity: O(1)
    /// - Returns: The resource if it exists, otherwise nil.
    public borrowing func getResource<T: Resource>(_ resource: T.Type) -> T? {
        return self.resources.getResource(resource)
    }

    /// Get a resource from the world or initialize it if it doesn't exist.
    /// - Parameter type: The type of the resource to get or initialize.
    /// - Complexity: O(1)
    /// - Returns: The resource if it exists, otherwise the initialized resource.
    public func getOrInitResource<T: Resource & WorldInitable>(of type: T.Type) -> T {
        if let resource = self.getResource(T.self) {
            return resource
        }
        let resource = type.init(from: self)
        resources.insertResource(resource, tick: currentTick)
        return resource
    }

    /// Get a or create resource from the world and returns ref.
    /// - Parameter resource: The resource to get.
    /// - Complexity: O(1)
    /// - Returns: The resource if it exists, otherwise nil.
    public func getOrInitRefResource<T: Resource>(_: T.Type, constructor: () -> T) -> Ref<T> {
        if !self.resources.contains(T.self) {
            self.insertResource(constructor())
        }
        let resource = unsafe self.resources.getResourceData(T.self)?.getWithTick(T.self)
        return unsafe Ref(
            pointer: resource?.pointer,
            changeTick: .init(
                added: resource?.addedTick,
                change: resource?.changedTick,
                lastTick: lastTick,
                currentTick: currentTick
            )
        )
    }

    /// Get a resource from the world.
    /// - Parameter resource: The resource to get.
    /// - Complexity: O(1)
    /// - Returns: The resource if it exists, otherwise nil.
    public func getRefResource<T: Resource>(_: T.Type) -> Ref<T> {
        let resource = unsafe self.resources.getResourceData(T.self)?.getWithTick(T.self)
        return unsafe Ref(
            pointer: resource?.pointer,
            changeTick: .init(
                added: resource?.addedTick,
                change: resource?.changedTick,
                lastTick: lastTick,
                currentTick: currentTick
            )
        )
    }

    /// Get all resources from the world.
    /// - Returns: All resources in world.
    public func getResources() -> [any Resource] {
        return self.resources.getResources()
    }

    /// Clear all resources from the world.
    /// - Complexity: O(1)
    public func clearResources() {
        self.resources.clear()
    }
}

// MARK: - Entities and Components

extension World {
    @discardableResult
    public func spawn(
        _ name: String = "",
        @ComponentsBuilder components: () -> ComponentsBundle
    ) -> Entity {
        self.spawn(name, bundle: components())
    }

    @discardableResult
    public func spawn<T: ComponentsBundle>(
        _ name: String = "",
        bundle: consuming T
    ) -> Entity {
        let entity = entities.allocate(with: name)
        insertNewEntity(entity, components: bundle.components)
        return entity
    }

    @discardableResult
    @inline(__always)
    public func spawn(_ name: String = "") -> Entity {
        let entity = entities.allocate(with: name)
        insertNewEntity(entity, components: [])
        return entity
    }

    public func get<T: Component>(from entity: Entity.ID) -> T? {
        guard let location = self.entities.entities[entity] else {
            return nil
        }
        return self.archetypes
            .archetypes[location.archetypeId]
            .chunks
            .chunks[location.chunkIndex]
            .get(at: location.chunkRow)
    }

    @inline(__always)
    public func get<T: Component>(_: T.Type, from entity: Entity.ID) -> T? {
        return self.get(from: entity)
    }

    public func insert<T: Component>(_ component: T, for entityId: Entity.ID) {
        guard let location = self.entities.entities[entityId] else {
            return
        }

        // We have component in archetype, just update
        var archetype = self.archetypes.archetypes[location.archetypeId]
        if archetype.componentLayout.maskSet.contains(T.identifier) {
            self.archetypes
                .archetypes[location.archetypeId]
                .chunks
                .chunks[location.chunkIndex]
                .insert(component, at: location.chunkRow, lastTick: currentTick)
            return
        }

        // Prepare new layout
        var newLayout = archetype.componentLayout
        newLayout.insert(T.self)

        var components: [any Component] = []
        for requiredComponent in componentsStorage.getRequiredComponents(for: T.self) {
            guard !newLayout.maskSet.contains(requiredComponent.id) else {
                continue
            }
            let newComponent = requiredComponent.constructor()
            components.append(newComponent)
            newLayout.insert(type(of: newComponent))
        }
        for requiredComponent in T.requiredComponents.components {
            guard !newLayout.maskSet.contains(requiredComponent.identifier) else {
                continue
            }
            let newComponent = requiredComponent.defaultValue
            components.append(newComponent)
            newLayout.insert(type(of: newComponent))
        }

        // Move entity to new archetype
        if let newArchetype = archetype.edges.getArchetypeAfterInsertion(for: newLayout) {
            self.moveEntityToArchetype(
                entityId,
                oldLocation: location,
                newArchetype: newArchetype
            )
        } else {
            let newArchetype = self.archetypes.getOrCreate(for: newLayout)
            archetype.edges.addArchetypeAfterInsertion(newArchetype, for: newLayout)
            self.archetypes.archetypes[location.archetypeId] = archetype
            self.moveEntityToArchetype(
                entityId,
                oldLocation: location,
                newArchetype: newArchetype
            )
        }

        // Insert components
        guard let newLocation = self.entities.entities[entityId] else {
            assertionFailure("Failed to insert component to entity")
            return
        }

        for component in components {
            self.archetypes
                .archetypes[newLocation.archetypeId]
                .chunks
                .insert(component, for: entityId, lastTick: currentTick)
        }

        self.archetypes
            .archetypes[newLocation.archetypeId]
            .chunks
            .insert(component, for: entityId, lastTick: currentTick)
    }

    @inline(__always)
    public func remove<T: Component>(_: consuming T, for entity: Entity.ID) {
        self.remove(T.identifier, from: entity)
    }

    /// Remove a component of the specified type from an entity.
    /// - Parameter componentType: The type of component to remove.
    /// - Parameter entity: The entity ID to remove the component from.
    @inline(__always)
    public func remove<T: Component>(_: T.Type, from entityId: Entity.ID) {
        guard let location = entities.entities[entityId] else {
            return
        }
        let entity = self.archetypes.archetypes[location.archetypeId].entities[location.archetypeRow]
        eventManager.send(ComponentEvents.WillRemove(componentType: T.self, entity: entity))
        self.remove(T.identifier, from: entityId)
    }

    public func remove(_ componentId: ComponentId, from entityId: Entity.ID) {
        // Get the entity's current location
        guard let location = self.entities.entities[entityId] else {
            return  // Entity doesn't exist in the world
        }

        // Get the entity from the archetype
        var archetype = self.archetypes.archetypes[location.archetypeId]
        var newLayout = archetype.chunks.componentLayout
        newLayout.remove(componentId)
        if let newArchetype = archetype.edges.getArchetypeAfterRemoval(for: newLayout) {
            self.moveEntityToArchetype(
                entityId,
                oldLocation: location,
                newArchetype: newArchetype
            )
        } else {
            let newArchetype = self.archetypes.getOrCreate(for: newLayout)
            archetype.edges.addArchetypeAfterRemoval(newArchetype, for: newLayout)
            self.archetypes.archetypes[location.archetypeId] = archetype
            self.moveEntityToArchetype(
                entityId,
                oldLocation: location,
                newArchetype: newArchetype
            )
        }
        self.removedComponents[entityId, default: []].insert(componentId)
    }

    @inline(__always)
    @discardableResult
    public func registerRequiredComponent<T: Component, R: Component & DefaultValue>(
        _ requiredComponent: R.Type,
        for component: T.Type
    ) -> Self {
        self.registerRequiredComponent(requiredComponent, for: component) {
            R.defaultValue
        }
    }

    @discardableResult
    public func registerRequiredComponent<T: Component, R: Component>(
        _ requiredComponent: R.Type,
        for component: T.Type,
        constructor: @Sendable @escaping () -> R
    ) -> Self {
        let componentId = self.componentsStorage.getOrRegisterComponent(component)
        let requiredComponentId = self.componentsStorage.getOrRegisterComponent(requiredComponent)
        self.componentsStorage.registerRequiredComponent(
            for: componentId,
            requiredComponentId: requiredComponentId,
            constructor: constructor
        )

        return self
    }

    @inline(__always)
    public func has<T: Component>(_: T.Type, in entity: Entity.ID) -> Bool {
        self.has(T.identifier, in: entity)
    }

    public func has(_ identifier: ComponentId, in entity: Entity.ID) -> Bool {
        guard let location = self.entities.entities[entity] else {
            return false
        }

        return self.archetypes
            .archetypes[location.archetypeId]
            .componentLayout
            .maskSet
            .contains(identifier)
    }
}

// MARK: - Queries

extension World {
    /// Returns all entities of the scene which pass the ``QueryPredicate`` of the query.
    public func performQuery(_ query: EntityQuery) -> EntityQuery.Result {
        let state = query.state
        state.updateArchetypes(in: self)
        return QueryResult(state: state)
    }

    /// Returns all components of the scene which pass the ``FilterQuery``.
    public func performQuery<each T: QueryTarget, F: Filter>(
        _ query: FilterQuery<repeat (each T), F>
    ) -> QueryResult<FilterQuery<repeat (each T), F>.Builder, F> {
        let state = query.state
        state.updateArchetypes(in: self)
        return QueryResult(state: state)
    }
}

extension World: EventSource {
    /// Subscribe to an event.
    /// - Parameter event: The event to subscribe to.
    /// - Parameter eventSource: The event source to subscribe to.
    /// - Parameter completion: The completion handler to call when the event is triggered.
    /// - Returns: A cancellable object that can be used to unsubscribe from the event.
    public func subscribe<E: Event>(
        to event: E.Type,
        on eventSource: EventSource?,
        completion: @escaping @Sendable (E) -> Void
    ) -> Cancellable {
        self.eventManager.subscribe(to: event, on: eventSource, completion: completion)
    }
}

extension World {
    /// Insert entity to the world. Expect, that entity is already stored in `Entities`.
    func insertNewEntity(_ entity: Entity, components: [any Component]) {
        let components: [any Component] = components.reduce(into: []) { partialResult, component in
            for requiredComponent in componentsStorage.getRequiredComponents(for: component) {
                partialResult.append(requiredComponent.constructor())
            }
            for requiredComponent in type(of: component).requiredComponents.components {
                partialResult.append(requiredComponent.defaultValue)
            }
            partialResult.append(component)
        }
        let componentsLayout = ComponentLayout(components: components)
        let archetypeIndex = self.archetypes.getOrCreate(
            for: componentsLayout
        )

        var archetype = self.archetypes.archetypes[archetypeIndex]
        let row = archetype.append(entity)
        let chunkLocation = archetype.chunks.insertEntity(
            entity.id,
            components: components,
            tick: self.currentTick
        )
        self.archetypes.archetypes[archetypeIndex] = archetype
        self.entities.insert(
            EntityLocation(
                archetypeId: archetype.id,
                archetypeRow: row,
                chunkIndex: chunkLocation.chunkIndex,
                chunkRow: chunkLocation.entityRow
            ),
            for: entity.id
        )
        entity.world = self
        addedEntities.insert(entity.id)
        eventManager.send(WorldEvents.DidAddEntity(entity: entity), source: self)
    }

    /// Move entity to new archetype.
    private func moveEntityToArchetype(
        _ entityId: Entity.ID,
        oldLocation location: EntityLocation,
        newArchetype: Archetype.ID
    ) {
        var archetype = self.archetypes.archetypes[location.archetypeId]
        let entity = archetype.entities[location.archetypeRow]
        var toArchetype = self.archetypes.archetypes[newArchetype]
        let row = toArchetype.append(entity)
        let result = archetype.swapRemove(at: location.archetypeRow)
        let moveResult = archetype.chunks.moveEntity(entityId, to: &toArchetype.chunks)
        let newLocation = moveResult.newLocation

        var updatedLocations: [Entity.ID: EntityLocation] = [:]

        func updateLocation(
            for entity: Entity.ID,
            _ update: (EntityLocation) -> EntityLocation
        ) {
            guard let currentLocation = updatedLocations[entity] ?? entities.entities[entity] else {
                return
            }
            updatedLocations[entity] = update(currentLocation)
        }

        if let swappedEntity = result.swappedEntity {
            updateLocation(for: swappedEntity) { currentLocation in
                EntityLocation(
                    archetypeId: location.archetypeId,
                    archetypeRow: location.archetypeRow,
                    chunkIndex: currentLocation.chunkIndex,
                    chunkRow: currentLocation.chunkRow
                )
            }
        }

        if let swappedEntity = moveResult.swappedEntity {
            updateLocation(for: swappedEntity) { currentLocation in
                EntityLocation(
                    archetypeId: currentLocation.archetypeId,
                    archetypeRow: currentLocation.archetypeRow,
                    chunkIndex: location.chunkIndex,
                    chunkRow: location.chunkRow
                )
            }
        }

        for (entity, location) in updatedLocations {
            entities.insert(location, for: entity)
        }

        self.archetypes.archetypes[location.archetypeId] = archetype
        self.archetypes.archetypes[newArchetype] = toArchetype
        self.entities.insert(
            EntityLocation(
                archetypeId: newArchetype,
                archetypeRow: row,
                chunkIndex: newLocation.chunkIndex,
                chunkRow: newLocation.entityRow
            ),
            for: entityId
        )
    }

    /// Remove entity record.
    /// - Parameter entity: The entity to remove.
    private func removeEntityRecord(_ entity: Entity.ID) {
        guard let record = self.entities.entities[entity] else {
            return
        }
        self.entities.remove(entity)

        var currentArchetype = self.archetypes.archetypes[record.archetypeId]
        let removeResult = currentArchetype.swapRemove(at: record.archetypeRow)

        if let swappedEntity = removeResult.swappedEntity,
            let swappedLocation = entities.entities[swappedEntity] {
            entities.insert(
                EntityLocation(
                    archetypeId: swappedLocation.archetypeId,
                    archetypeRow: record.archetypeRow,
                    chunkIndex: swappedLocation.chunkIndex,
                    chunkRow: swappedLocation.chunkRow
                ),
                for: swappedEntity
            )
        }

        let removeChunkResult = currentArchetype.chunks.removeEntity(entity)
        if let removeChunkResult, let swappedEntity = removeChunkResult.swappedEntity {
            if let swappedLocation = entities.entities[swappedEntity] {
                entities.insert(
                    EntityLocation(
                        archetypeId: swappedLocation.archetypeId,
                        archetypeRow: swappedLocation.archetypeRow,
                        chunkIndex: removeChunkResult.newLocation.chunkIndex,
                        chunkRow: removeChunkResult.newLocation.entityRow
                    ),
                    for: swappedEntity
                )
            }
        }

        self.archetypes.archetypes[record.archetypeId] = currentArchetype
    }
}

/// Events the world triggers.
public enum WorldEvents {
    /// Raised after an entity is added to the scene.
    public struct DidAddEntity: Event {
        public let entity: Entity
    }

    /// Raised before an entity is removed from the scene.
    public struct WillRemoveEntity: Event {
        public let entity: Entity
    }
}

extension World {
    private enum CodingKeys: String, CodingKey {
        case name
        case entities
        case resources
        case systems
        case plugins
    }
}

public struct ChangeDetectionTick: Sendable {
    public var added: UnsafeBox<Tick>?
    public var change: UnsafeBox<Tick>?
    public let lastTick: Tick
    public let currentTick: Tick

    public init(added: UnsafeBox<Tick>?, change: UnsafeBox<Tick>?, lastTick: Tick, currentTick: Tick) {
        self.added = added
        self.change = change
        self.lastTick = lastTick
        self.currentTick = currentTick
    }
}

public struct Tick: Sendable, Comparable {
    public let value: Int

    public init(value: Int) {
        self.value = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public func isNewerThan(lastTick: Self, currentTick: Self) -> Bool {
        let changeTickSince = currentTick.value &- self.value
        let lastTickSince = currentTick.value &- lastTick.value
        return lastTickSince > changeTickSince
    }
}
