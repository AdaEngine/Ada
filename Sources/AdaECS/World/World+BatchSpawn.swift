import AdaUtils

extension World {
    /// Creates entities by preparing components in index order, then inserting
    /// groups by archetype into chunk storage. Nonpositive counts return an empty array.
    ///
    /// Builders and required factories run once per entity before batch insertion;
    /// they cannot observe other entities from this batch yet. Entity IDs are
    /// allocated after preparation. All rows use the current tick at insertion.
    /// `DidAddEntity` is sent in index order after the entire batch is registered.
    /// Event callbacks may mutate the world or spawn more entities normally.
    ///
    /// Different component layouts, runtime schemas and changing requirements are
    /// supported. Values and returned entities follow the builder's index order.
    ///
    /// ```swift
    /// let particles = world.spawnBatch(count: 10_000) { index in
    ///     Position(x: Float(index), y: 0)
    ///     Velocity(x: 1, y: 0)
    /// }
    /// ```
    @discardableResult
    public func spawnBatch(
        count: Int,
        name: String = "",
        @ComponentsBuilder components: (Int) -> ComponentsBundle
    ) -> [Entity] {
        guard count > 0 else {
            return []
        }
        var values: [[any Component]] = []
        var targets: [Archetype.ID] = []
        var groups: [Archetype.ID: [Int]] = [:]
        values.reserveCapacity(count)
        for index in 0..<count {
            let (prepared, target) = prepareSpawnComponents(components(index).components)
            values.append(prepared)
            if groups[target] == nil { targets.append(target) }
            groups[target, default: []].append(index)
        }

        let batch = entities.allocateBatch(count: count, name: name)
        let tick = currentTick
        var locations = Array(
            repeating: EntityLocation(archetypeId: 0, archetypeRow: 0, chunkIndex: 0, chunkRow: 0),
            count: count
        )
        for target in targets {
            guard let indices = groups[target] else {
                continue
            }
            archetypes.archetypes[target].reserveBatchCapacity(indices.count)
            let firstRow = archetypes.archetypes[target].entities.count
            archetypes.archetypes[target].entities.append(contentsOf: indices.lazy.map { batch[$0] })
            let chunkLocations = archetypes.archetypes[target].chunks.insertBatch(
                batch,
                components: values,
                indices: indices,
                tick: tick
            )
            for offset in chunkLocations.indices {
                let chunk = chunkLocations[offset]
                locations[indices[offset]] = EntityLocation(
                    archetypeId: archetypes.archetypes[target].id,
                    archetypeRow: firstRow + offset,
                    chunkIndex: chunk.chunkIndex,
                    chunkRow: chunk.entityRow
                )
            }
        }
        registerSpawnBatch(batch, locations: locations)
        // Release staging owners only after all storage borrows and registration
        // have finished. The cache itself never owns these constructed values.
        values.removeAll()
        for entity in batch {
            eventManager.send(WorldEvents.DidAddEntity(entity: entity), source: self)
        }
        return batch
    }
}
