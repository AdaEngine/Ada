//
//  SystemQuery.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/21/25.
//

import AdaUtils
import Foundation

/// A query that can fetch query targets like components or entities.
///
/// Use queries to efficiently access and iterate over entities and their components that match specific criteria.
///
/// ```swift
/// // Query for entities with both Position and Velocity components
/// @Query<Entity, Ref<Position>, Ref<Velocity>>
/// var movingEntities
///
/// // Query for just Position components
/// @Query<Position>
/// var positions
///
/// // Query with multiple component references
/// @Query<Position, Rotation>
/// var transforms
/// ```
public typealias Query<each T: QueryTarget> = FilterQuery<repeat (each T), NoFilter>

/// A query that can fetch query targets like components or entities with filters.
///
/// Use queries to efficiently access and iterate over entities and their components that match specific criteria.
///
/// ```swift
/// // Query for entities with Position or Velocity components
/// @FilterQuery<Entity, Ref<Position>, Or<Ref<Velocity>>>
/// var movingEntities
///
/// // Query for just Position components
/// @FilterQuery<Position, NoFilter>
/// var positions
///
/// // Query without Rotation component
/// @FilterQuery<Position, Without<Rotation>>
/// var transforms
/// ```
@propertyWrapper
public struct FilterQuery<each T: QueryTarget, F: Filter>: Sequence, Sendable {
    /// The element type of the query result.
    public typealias Element = Builder.Components

    /// The iterator type of the query result.
    public typealias Iterator = FilterQueryIterator<Builder, F>

    public typealias Builder = QueryBuilderTargets<repeat each T>

    public var wrappedValue: Self {
        _read { yield self }
    }

    let state: QueryState

    /// Create a new query for specific predicate.
    /// - Parameter predicate: Describe what entity should contains to satisfy query.
    public init() {
        self.state = QueryState(
            predicate: .init(
                evaluate: { Builder.predicate(in: $0) && QueryBuilderTargets<F>.predicate(in: $0) }
            ),
            filter: .all
        )
    }

    public init(from world: World) {
        self.state = QueryState(
            predicate: .init(
                evaluate: { Builder.predicate(in: $0) && QueryBuilderTargets<F>.predicate(in: $0) }
            ),
            filter: .all
        )
        self.state.updateArchetypes(in: world)
    }
}

/// Contains array of entities matched for the given EntityQuery request.
extension FilterQuery {
    /// Returns first element of collection.
    public var first: Element? {
        return self.first { _ in return true }
    }

    /// Calculate count of element in collection
    /// - Complexity: O(n)
    public var count: Int {
        return self.count { _ in return true }
    }

    /// A Boolean value indicating whether the collection is empty.
    public var isEmpty: Bool {
        return self.state.archetypeIndecies.isEmpty
    }

    public func makeIterator() -> Iterator {
        Iterator(state: self.state)
    }

    /// Returns a parallel query processor for concurrent iteration over chunks.
    ///
    /// Use this method to process query results in parallel across multiple threads.
    /// The batch size determines how many chunks are grouped together in a single task,
    /// which helps balance the workload across available CPU cores.
    ///
    /// ```swift
    /// // Process entities in parallel with custom batch size
    /// await query.parallel(batchSize: 8).forEach { position, velocity in
    ///     position.x += velocity.x * deltaTime
    ///     position.y += velocity.y * deltaTime
    /// }
    ///
    /// // Map entities in parallel and collect results
    /// let distances = await query.parallel().map { position in
    ///     return sqrt(position.x * position.x + position.y * position.y)
    /// }
    /// ```
    ///
    /// - Parameter batchSize: Number of chunks to process per task. Default is 4.
    ///   Larger values reduce task overhead but may cause load imbalance.
    ///   Smaller values provide better load distribution but increase task overhead.
    /// - Returns: A ``ParallelQueryResult`` instance for concurrent processing
    public func parallel(batchSize: Int = 4) -> ParallelQueryResult<Builder, F> {
        return ParallelQueryResult(state: self.state, batchSize: batchSize)
    }
}

extension FilterQuery: SystemParameter {
    public static var access: SystemAccessSet {
        Builder.access.union(QueryBuilderTargets<F>.access)
    }

    public func update(from world: World) {
        self.state.updateArchetypes(in: world)
    }
}

@usableFromInline
final class QueryState: @unchecked Sendable {
    @usableFromInline
    private(set) var archetypeIndecies: [Int] = []

    @usableFromInline
    private(set) unowned var entities: Entities!

    @usableFromInline
    private(set) unowned var world: World!

    @usableFromInline
    private(set) var lastTick: Tick = Tick(value: 0)

    @usableFromInline
    let predicate: QueryPredicate

    @usableFromInline
    let filter: QueryFilter

    @usableFromInline
    internal init(predicate: QueryPredicate, filter: QueryFilter) {
        self.predicate = predicate
        self.filter = filter
    }

    @usableFromInline
    func updateArchetypes(in world: World) {
        self.entities = world.entities
        self.archetypeIndecies.removeAll(keepingCapacity: true)
        for (index, archetype) in world.archetypes.archetypes.enumerated() where self.predicate.evaluate(archetype) {
            self.archetypeIndecies.append(index)
        }
        self.lastTick = world.lastTick
        self.world = world
    }
}

/// This iterator iterate by each entity in passed archetype array
public struct FilterQueryIterator<
    B: QuertyTargetBuilder,
    F: Filter
>: IteratorProtocol {
    public typealias Element = B.Components

    @usableFromInline
    struct Cursor {
        @usableFromInline
        var currentArchetypeIndex = 0

        @usableFromInline
        var currentChunkIndex = 0

        /// Current row in chunk
        @usableFromInline
        var currentRow = 0

        /// Current length in chunk
        @usableFromInline
        var currentLength = 0
    }

    @usableFromInline
    unowned let archetypes: Archetypes

    @usableFromInline
    let count: Int

    @usableFromInline
    let state: QueryState

    @usableFromInline
    var cursor: Cursor

    @usableFromInline
    var fetches: B.ComponentsFetches

    @usableFromInline
    var states: B.ComponentsStates

    @usableFromInline
    var filterState: F.State

    @usableFromInline
    var filterFetch: F.Fetch

    @usableFromInline
    let requiresRowEvaluation: Bool

    @usableFromInline
    var needsUpdateData = true

    @usableFromInline
    init(state: QueryState) {
        self.count = state.archetypeIndecies.count
        self.state = state
        self.cursor = Cursor()
        self.archetypes = state.world.archetypes

        self.states = B.initState(world: state.world)
        self.fetches = B.initFetches(
            world: state.world,
            states: self.states,
            lastTick: state.lastTick
        )
        self.filterState = F._initState(world: state.world)
        self.filterFetch = F._initFetch(
            world: state.world,
            state: filterState,
            lastTick: state.lastTick,
            currentTick: state.world.currentTick
        )
        self.requiresRowEvaluation = F.requiresRowEvaluation
    }

    @inlinable
    public mutating func next() -> Element? {
        // swiftlint:disable:next empty_count
        guard count > 0 && !archetypes.archetypes.isEmpty else {
            return nil
        }

        while true {
            guard cursor.currentArchetypeIndex < self.count else {
                return nil
            }

            let archetypeIndex = state.archetypeIndecies[cursor.currentArchetypeIndex]
            let archetype = self.archetypes.archetypes[archetypeIndex]

            if archetype.isEmpty {
                cursor.currentArchetypeIndex += 1
                cursor.currentChunkIndex = 0
                needsUpdateData = true
                continue
            }

            if cursor.currentChunkIndex >= archetype.chunks.chunks.count {
                cursor.currentArchetypeIndex += 1
                cursor.currentChunkIndex = 0
                cursor.currentRow = 0
                needsUpdateData = true
                updateStates()
                continue
            }

            if cursor.currentRow >= archetype.chunks.chunks[cursor.currentChunkIndex].count {
                cursor.currentChunkIndex += 1
                cursor.currentRow = 0
                needsUpdateData = true
                updateStates()
                continue
            }

            let currentChunk = archetype.chunks.chunks[cursor.currentChunkIndex]
            if needsUpdateData {
                B.setChunk(
                    states: states,
                    fetches: &fetches,
                    chunk: currentChunk,
                    archetype: archetype
                )
                filterFetch = F._setData(
                    state: filterState,
                    fetch: filterFetch,
                    chunk: currentChunk,
                    archetype: archetype
                )
                needsUpdateData = false
            }

            let entityId = currentChunk.entities[cursor.currentRow]

            defer {
                cursor.currentRow += 1
            }

            if requiresRowEvaluation {
                guard
                    F.condition(
                        state: filterState,
                        fetch: filterFetch,
                        at: cursor.currentRow
                    )
                else {
                    continue
                }
            }

            guard let location = state.entities.entities[entityId] else {
                continue
            }
            let entity = archetype.entities[location.archetypeRow]

            if let value = B.getQueryTargets(
                for: entity,
                states: states,
                fetches: fetches,
                at: cursor.currentRow
            ) {
                return value
            }
        }
    }

    @usableFromInline
    mutating func updateStates() {
        states = B.initState(world: state.world)
        fetches = B.initFetches(
            world: state.world,
            states: states,
            lastTick: state.lastTick
        )
        filterState = F._initState(world: state.world)
        filterFetch = F._initFetch(
            world: state.world,
            state: filterState,
            lastTick: state.lastTick,
            currentTick: state.world.currentTick
        )
    }
}
