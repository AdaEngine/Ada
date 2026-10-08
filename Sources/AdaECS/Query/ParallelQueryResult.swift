//
//  ParallelQueryResult.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.11.2025.
//

import AdaUtils

/// Information about a chunk location for parallel processing.
private struct ChunkInfo: Sendable {
    let archetypeIndex: Int
    let chunkIndex: Int
}

/// A parallel query processor that iterates over chunks concurrently.
///
/// Use this to process query results in parallel across multiple threads.
/// The batch size determines how many chunks are processed in a single task.
///
/// ```swift
/// // Process entities in parallel
/// await query.parallel(batchSize: 4).forEach { position, velocity in
///     // Process each entity concurrently
///     position.x += velocity.x
/// }
/// ```
public struct ParallelQueryResult<B: QuertyTargetBuilder, F: Filter>: Sendable {
    public typealias Element = B.Components

    let state: QueryState
    let batchSize: Int

    /// Process each element in parallel using a TaskGroup.
    /// - Parameter operation: The operation to perform on each element
    @concurrent
    public func forEach(
        _ operation: @escaping @Sendable (Element) async throws -> Void
    ) async rethrows where Element: Sendable {
        let batches = collectBatches()
        let state = self.state

        try await withThrowingTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask { [state] in
                    try await Self.processBatch(batch, state: state, operation: operation)
                }
            }

            for try await _ in group {}
        }
    }

    /// Map each element in parallel and collect results.
    /// - Parameter transform: The transformation to apply to each element
    /// - Returns: Array of transformed results
    @concurrent
    public func map<T: Sendable>(
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async rethrows -> [T] {
        let batches = collectBatches()
        let state = self.state

        return try await withThrowingTaskGroup(of: [T].self) { group in
            for batch in batches {
                group.addTask { [state] in
                    try await Self.mapBatch(batch, state: state, transform: transform)
                }
            }

            var results: [T] = []
            for try await batchResults in group {
                results.append(contentsOf: batchResults)
            }
            return results
        }
    }

    /// Collect all chunks into batches for parallel processing.
    @inline(__always)
    private func collectBatches() -> [[ChunkInfo]] {
        guard let world = state.world else {
            return []
        }

        var allChunks: [ChunkInfo] = []

        // Collect all chunks from all matching archetypes
        for archetypeIndex in state.archetypeIndecies {
            guard archetypeIndex < world.archetypes.archetypes.count else {
                continue
            }

            let archetype = world.archetypes.archetypes[archetypeIndex]
            for chunkIndex in 0..<archetype.chunks.chunks.count {
                allChunks.append(
                    ChunkInfo(
                        archetypeIndex: archetypeIndex,
                        chunkIndex: chunkIndex
                    )
                )
            }
        }

        // Split chunks into batches
        return stride(from: 0, to: allChunks.count, by: batchSize)
            .map { startIndex in
                let endIndex = min(startIndex + batchSize, allChunks.count)
                return Array(allChunks[startIndex..<endIndex])
            }
    }

    /// Process a batch of chunks with the given operation.
    @concurrent
    private static func processBatch(
        _ batch: [ChunkInfo],
        state: QueryState,
        operation: @Sendable (Element) async throws -> Void
    ) async rethrows {
        guard let world = state.world else {
            return
        }

        let requiresRowEvaluation = F.requiresRowEvaluation
        let states = B.initState(world: world)
        var fetches = B.initFetches(world: world, states: states, lastTick: state.lastTick)
        let filterState = F._initState(world: world)
        var filterFetch = F._initFetch(
            world: world,
            state: filterState,
            lastTick: state.lastTick,
            currentTick: world.currentTick
        )

        for chunkInfo in batch {
            let archetypes = world.archetypes
            guard chunkInfo.archetypeIndex < archetypes.archetypes.count else {
                continue
            }

            let archetype = archetypes.archetypes[chunkInfo.archetypeIndex]
            guard chunkInfo.chunkIndex < archetype.chunks.chunks.count else {
                continue
            }

            let chunk = archetype.chunks.chunks[chunkInfo.chunkIndex]
            B.setChunk(
                states: states,
                fetches: &fetches,
                chunk: chunk,
                archetype: archetype
            )
            filterFetch = F._setData(
                state: filterState,
                fetch: filterFetch,
                chunk: chunk,
                archetype: archetype
            )

            // Iterate over all entities in this chunk
            for row in 0..<chunk.count {
                if requiresRowEvaluation {
                    guard
                        F.condition(
                            state: filterState,
                            fetch: filterFetch,
                            at: row
                        )
                    else {
                        continue
                    }
                }

                let entityId = chunk.entities[row]
                guard let location = state.entities.entities[entityId] else {
                    continue
                }

                let entity = archetype.entities[location.archetypeRow]
                if let element = B.getQueryTargets(
                    for: entity,
                    states: states,
                    fetches: fetches,
                    at: row
                ) {
                    try await operation(element)
                }
            }
        }
    }

    /// Map a batch of chunks with the given transform.
    @concurrent
    private static func mapBatch<T: Sendable>(
        _ batch: [ChunkInfo],
        state: QueryState,
        transform: @Sendable (Element) async throws -> T
    ) async rethrows -> [T] {
        guard let world = state.world else {
            return []
        }

        let requiresRowEvaluation = F.requiresRowEvaluation
        let states = B.initState(world: world)
        var fetches = B.initFetches(world: world, states: states, lastTick: state.lastTick)
        let filterState = F._initState(world: world)
        var filterFetch = F._initFetch(
            world: world,
            state: filterState,
            lastTick: state.lastTick,
            currentTick: world.currentTick
        )

        var results: [T] = []

        for chunkInfo in batch {
            let archetypes = world.archetypes
            guard chunkInfo.archetypeIndex < archetypes.archetypes.count else {
                continue
            }

            let archetype = archetypes.archetypes[chunkInfo.archetypeIndex]
            guard chunkInfo.chunkIndex < archetype.chunks.chunks.count else {
                continue
            }

            let chunk = archetype.chunks.chunks[chunkInfo.chunkIndex]
            B.setChunk(
                states: states,
                fetches: &fetches,
                chunk: chunk,
                archetype: archetype
            )
            filterFetch = F._setData(
                state: filterState,
                fetch: filterFetch,
                chunk: chunk,
                archetype: archetype
            )

            // Iterate over all entities in this chunk
            for row in 0..<chunk.count {
                let entityId = chunk.entities[row]
                guard let location = state.entities.entities[entityId] else {
                    continue
                }

                let entity = archetype.entities[location.archetypeRow]

                if requiresRowEvaluation {
                    guard
                        F.condition(
                            state: filterState,
                            fetch: filterFetch,
                            at: row
                        )
                    else {
                        continue
                    }
                }

                if let element = B.getQueryTargets(
                    for: entity,
                    states: states,
                    fetches: fetches,
                    at: row
                ) {
                    let result = try await transform(element)
                    results.append(result)
                }
            }
        }

        return results
    }
}
