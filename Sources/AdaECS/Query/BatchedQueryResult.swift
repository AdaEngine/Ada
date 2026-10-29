import AdaUtils

/// Sequential query traversal that keeps column bindings for the current chunk.
/// Structural mutations must be deferred until `forEach` returns. No component
/// pointer or chunk metadata is retained after the traversal.
public struct BatchedQueryResult<B: QuertyTargetBuilder, F: Filter>: Sendable {
    @usableFromInline let state: QueryState

    init(state: QueryState) { self.state = state }

    /// Visits matching rows in query order, preserving filters and `Ref` change ticks.
    @inlinable
    public func forEach(_ operation: (B.Components) throws -> Void) rethrows {
        guard let world = state.world else { return }
        let requiresEntity = B.requiresEntity
        let requiresRowEvaluation = F.requiresRowEvaluation
        for archetypeIndex in state.archetypeIndecies {
            let archetype = world.archetypes.archetypes[archetypeIndex]
            for chunk in archetype.chunks.chunks where !chunk.isEmpty {
                // Match the ordinary iterator's per-chunk target/filter state lifetime.
                let states = B.initState(world: world)
                var fetches = B.initFetches(world: world, states: states, lastTick: state.lastTick)
                let filterState = F._initState(world: world)
                var filterFetch = F._initFetch(world: world, state: filterState, lastTick: state.lastTick, currentTick: world.currentTick)
                B.setChunk(states: states, fetches: &fetches, chunk: chunk, archetype: archetype)
                filterFetch = F._setData(state: filterState, fetch: filterFetch, chunk: chunk, archetype: archetype)
                for row in 0..<chunk.count {
                    if requiresRowEvaluation, !F.condition(state: filterState, fetch: filterFetch, at: row) { continue }
                    let entity: Entity
                    if requiresEntity {
                        guard let location = state.entities.entities[chunk.entities[row]] else { continue }
                        entity = archetype.entities[location.archetypeRow]
                    } else {
                        entity = Entity.queryPlaceholder
                    }
                    if let value = B.getQueryTargets(for: entity, states: states, fetches: fetches, at: row) {
                        try operation(value)
                    }
                }
            }
        }
    }
}
