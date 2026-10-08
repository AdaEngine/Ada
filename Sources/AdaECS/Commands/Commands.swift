//
//  Commands.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.06.2025.
//

import AdaUtils
import Collections
import DequeModule
import Foundation

public final class WorldCommandQueue: @unchecked Sendable {
    var commands: Deque<WorldCommand> = []
    let lock = NSRecursiveLock()

    public var isEmpty: Bool {
        commands.isEmpty
    }

    public init() {}

    init(_ commands: Deque<WorldCommand>) {
        self.commands = commands
    }

    public func push(_ command: @escaping @Sendable (World) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.commands.append(WorldCommand(applyToWorld: command))
    }

    public func apply(to world: World) {
        world.flushCommands()
        applyAndDrop(to: world)
    }

    public func copy() -> WorldCommandQueue {
        WorldCommandQueue(commands)
    }

    func applyAndDrop(to world: World) {
        while let drop = commands.popFirst() {
            drop.applyToWorld(world)
        }
    }
}

public struct WorldCommand: Sendable {
    let applyToWorld: @Sendable (World) -> Void

    public init(applyToWorld: @escaping @Sendable (World) -> Void) {
        self.applyToWorld = applyToWorld
    }
}

@propertyWrapper
public final class Commands: @unchecked Sendable {
    public var entities: Entities
    public private(set) var queue: WorldCommandQueue

    public var isEmpty: Bool {
        self.queue.isEmpty
    }

    public var wrappedValue: Commands {
        self
    }

    public init() {
        entities = .init()
        queue = .init()
    }

    public init(entities: Entities, commandsQueue: WorldCommandQueue) {
        self.entities = entities
        self.queue = commandsQueue
    }
}

extension Commands: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addDeferredWorldAccess()
        return access
    }

    public convenience init(from world: World) {
        self.init(entities: world.entities, commandsQueue: world.commandQueue)
    }

    public func update(from world: World) {
        self.entities = world.entities
    }

    public func finish(_ world: World) {
        queue.apply(to: world)
    }
}

extension Commands {
    public func append(_ commands: Commands) {
        self.queue.commands.append(contentsOf: commands.queue.commands)
    }

    @discardableResult
    public func spawn(
        _ name: String = "",
        @ComponentsBuilder components: @escaping @Sendable () -> ComponentsBundle
    ) -> EntityCommands {
        let entity = entities.allocate(with: name)
        self.queue.push { world in
            world.insertNewEntity(entity, components: components().components)
        }
        return EntityCommands(queue: queue, entityId: entity.id)
    }

    @discardableResult
    public func spawn<T: ComponentsBundle>(
        _ name: String = "",
        bundle: consuming T
    ) -> EntityCommands {
        let entity = entities.allocate(with: name)
        self.queue.push { [bundle] world in
            world.insertNewEntity(entity, components: bundle.components)
        }
        return EntityCommands(queue: queue, entityId: entity.id)
    }

    @discardableResult
    public func spawn(_ name: String = "") -> EntityCommands {
        let entity = entities.allocate(with: name)
        self.queue.push { world in
            world.insertNewEntity(entity, components: [])
        }
        return EntityCommands(queue: queue, entityId: entity.id)
    }

    @discardableResult
    public func insertEntity(_ entity: Entity) -> EntityCommands {
        entities.addNotAllocatedEntity(entity)
        queue.push { world in
            world.addEntity(entity)
        }
        return EntityCommands(queue: queue, entityId: entity.id)
    }

    @discardableResult
    public func entity(_ entity: Entity.ID) -> EntityCommands {
        EntityCommands(queue: queue, entityId: entity)
    }

    public func insertResource<T: Resource>(_ resource: T) {
        self.queue.push {
            $0.insertResource(resource)
        }
    }

    public func removeResource<T: Resource>(_: T.Type) {
        self.queue.push {
            $0.removeResource(T.self)
        }
    }

    /// Enqueues an entity spawn from component values detached from a scripting VM.
    @_spi(Scripting)
    @discardableResult
    public func spawn(detachedComponents components: [any Component]) -> EntityCommands {
        spawn(bundle: ChainedComponentsBundle(components))
    }

    /// Enqueues a type-erased component value detached from a scripting VM.
    @_spi(Scripting)
    @discardableResult
    public func insert(_ component: any Component, into entity: Entity.ID) -> EntityCommands {
        func insert<T: Component>(_ component: T) -> EntityCommands {
            self.entity(entity).insert(component)
        }
        return _openExistential(component, do: insert)
    }
}

@safe
public final class EntityCommands {
    var queue: WorldCommandQueue
    public let entityId: Entity.ID

    init(queue: WorldCommandQueue, entityId: Entity.ID) {
        self.queue = queue
        self.entityId = entityId
    }
}

extension EntityCommands {
    @discardableResult
    public func insert<T: Component>(_ component: consuming T) -> Self {
        self.queue.push { [component, entityId] world in
            world.insert(component, for: entityId)
        }
        return self
    }

    @discardableResult
    public func remove(_ componentId: ComponentId, from entity: Entity.ID) -> Self {
        self.queue.push { world in
            world.remove(componentId, from: entity)
        }
        return self
    }

    @discardableResult
    @inline(__always)
    public func addChild(
        _ child: Entity
    ) -> Self {
        self.queue.push { [entityId] world in
            let entity = world.getEntityByID(entityId)
            world.addEntity(child)
            entity?.addChild(child)
        }
        return self
    }

    @inline(__always)
    public func removeFromWorld(recursively: Bool = false) {
        self.queue.push { [entityId] world in
            world.removeEntity(entityId, recursively: recursively)
        }
    }

    @discardableResult
    @inline(__always)
    public func remove<T: Component>(_: consuming T) -> Self {
        self.remove(T.identifier, from: entityId)
    }

    /// Remove a component of the specified type from an entity.
    /// - Parameter componentType: The type of component to remove.
    /// - Parameter entity: The entity ID to remove the component from.
    @discardableResult
    @inline(__always)
    public func remove<T: Component>(_: T.Type, from entity: Entity.ID) -> Self {
        self.remove(T.identifier, from: entity)
    }
}
