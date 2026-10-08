//
//  Query.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/24/22.
//

import AdaUtils

/// This object describe query to ECS world.
///
/// ```swift
/// @PlainSystem
/// struct MovementSystem {
///     @EntityQuery(where: .has(Transform.self)) private var query
///
///     func update(context: UpdateContext) {
///         self.query.forEach {
///             var transform = entity.components[Transform.self]
///             // Do some movement
///         }
///     }
/// }
/// ```
///
/// Also, you can combine types in query using `&&` and `||` operators.
///
/// ```swift
/// @PlainSystem
/// struct RendererSystem {
///     @EntityQuery(where: .has(Sprite.self) && .has(Transform.self))
///     private var query
///
///     func update(context: UpdateContext) {
///         for entity in self.query {
///             // Get components from entity and do some render
///         }
///     }
/// }
/// ```
@propertyWrapper
@frozen public struct EntityQuery: Sendable {
    public typealias Result = QueryResult<QueryBuilderTargets<Entity>, NoFilter>

    public var wrappedValue: Result {
        return QueryResult(state: self.state)
    }

    let state: QueryState
    let predicate: QueryPredicate
    let filter: QueryFilter
    let declaredAccess: SystemAccessSet

    /// Create a new entity query for specific predicate.
    /// - Parameter predicate: Describe what entity should contains to satisfy query.
    /// - Parameter filter: Describe filter of this query. By default is ``Filter/all``
    public init(
        where predicate: QueryPredicate,
        filter: QueryFilter = .all,
        access: SystemAccessSet = SystemAccessSet()
    ) {
        self.predicate = predicate
        self.filter = filter
        self.declaredAccess = access
        self.state = QueryState(predicate: predicate, filter: filter)
    }

    // SystemParameter requires this initializer, while EntityQuery requires an explicit plan.
    // swiftlint:disable:next unavailable_function
    public init(from _: World) {
        preconditionFailure("EntityQuery must be initialized with an explicit predicate.")
    }

    public func callAsFunction() -> Result {
        .init(state: self.state)
    }
}

extension EntityQuery: SystemParameter {
    public var access: SystemAccessSet {
        declaredAccess
    }

    public func finish(_: World) {}

    public func update(from world: World) {
        self.state.updateArchetypes(in: world)
    }
}

// TODO: Make deprecated

/// This iterator iterate by each entity in passed archetype array
public struct EntityIterator: IteratorProtocol {
    let count: Int
    let state: QueryState

    private var currentArchetypeIndex = 0
    private var currentEntityIndex = -1  // We should use -1 for first iterating.

    /// - Parameter pointer: Pointer to archetypes array.
    /// - Parameter count: Count archetypes in array.
    init(state: QueryState) {
        self.count = state.archetypeIndecies.count
        self.state = state
    }

    public mutating func next() -> Entity? {
        // EntityIterator is not a Collection; its count is the traversal bound.
        // swiftlint:disable:next empty_count
        guard self.count > 0 else {
            return nil
        }

        guard let world = state.world else {
            return nil
        }

        while true {
            guard self.currentArchetypeIndex < self.count else {
                return nil
            }

            let currentArchetypeIndex = self.state.archetypeIndecies[self.currentArchetypeIndex]

            // Validate archetype index is within bounds
            guard currentArchetypeIndex < world.archetypes.archetypes.count else {
                self.currentArchetypeIndex += 1
                continue
            }

            let currentEntitiesCount = world.archetypes.archetypes[currentArchetypeIndex].entities.count
            if self.currentEntityIndex < currentEntitiesCount - 1 {
                self.currentEntityIndex += 1
            } else {
                self.currentArchetypeIndex += 1
                self.currentEntityIndex = -1
                continue
            }

            let currentArchetype = self.state.archetypeIndecies[self.currentArchetypeIndex]
            let entity = world.archetypes.archetypes[currentArchetype].entities[self.currentEntityIndex]
            guard entity.isActive else {
                continue
            }

            guard let world = self.state.world else {
                return nil
            }

            if self.state.filter.contains(.all) {
                return entity
            } else if self.state.filter.contains(.added) && world.addedEntities.contains(entity.id) {
                return entity
            } else if self.state.filter.contains(.removed) && world.removedEntities.contains(entity.id) {
                return entity
            } else if self.state.filter.contains(.stored) {
                return entity
            }

            continue
        }
    }
}
