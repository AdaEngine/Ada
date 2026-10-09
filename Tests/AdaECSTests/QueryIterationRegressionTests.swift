import AdaECS
import Testing

@Component
struct IterationPosition { var value: Int }

@Component
struct IterationVelocity { var value: Int }

@Component
struct IterationTagA {}

@Component
struct IterationTagB {}

// Uses only the existing public QueryTarget requirements. Returning nil from a
// row fetch must skip that row, rather than terminate the iterator.
struct SkippingEntityTarget: QueryTarget {
    let id: Entity.ID
    let name: String

    static func _initState(world _: World) {}
    static func _initFetch(world _: World, state _: Void, lastTick _: Tick, currentTick _: Tick) {}
    static func _setData(state _: Void, fetch _: Void, chunk _: Chunk, archetype _: Archetype) {}
    static func _queryTargetContains(in entity: Entity) -> Bool { entity.components.has(IterationPosition.self) }
    static func _queryContains(in archetype: borrowing Archetype) -> Bool {
        archetype.componentLayout.maskSet.contains(IterationPosition.identifier)
    }
    static func _queryFetch(for entity: Entity, state _: Void, fetch _: Void, at row: Int) -> Self? {
        row % 3 == 1 ? nil : Self(id: entity.id, name: entity.name)
    }
}

@Suite("Query iteration regressions")
struct QueryIterationRegressionTests {
    private func fixture(_ count: Int) -> (World, [Entity]) {
        let world = World()
        let entities = (0..<count).map { index in
            world.spawn {
                IterationPosition(value: index)
                IterationVelocity(value: 1)
                if index % 4 == 1 || index % 4 == 3 { IterationTagA() }
                if index % 4 == 2 || index % 4 == 3 { IterationTagB() }
            }
        }
        return (world, entities)
    }

    @Test("Read queries keep values and entity identity after deletion and migration")
    func readsAfterStructuralChanges() {
        let (world, entities) = fixture(2_400)
        let deleted = Set([0, 249, 1_000, 2_399])
        for index in deleted { world.removeEntity(entities[index]) }
        world.insert(IterationTagB(), for: entities[253].id)

        var values: [Int] = []
        Query<IterationPosition, IterationVelocity>(from: world).forEach { position, velocity in
            #expect(velocity.value == 1)
            values.append(position.value)
        }
        #expect(values.sorted() == (0..<entities.count).filter { !deleted.contains($0) })

        Query<Entity, IterationPosition>(from: world).forEach { entity, position in
            #expect(entity === entities[position.value])
        }
    }

    @Test("Iteration skips empty chunks and empty matching archetypes")
    func emptyChunksAndArchetypes() {
        let world = World()
        let tagged = (0..<10).map { index in world.spawn { IterationPosition(value: index); IterationTagA() } }
        let plain = (0..<800).map { index in world.spawn { IterationPosition(value: index) } }
        for entity in tagged { world.removeEntity(entity) }
        for index in 0..<250 { world.removeEntity(plain[index]) }

        var values: [Int] = []
        Query<IterationPosition>(from: world).forEach { position in values.append(position.value) }
        #expect(values.sorted() == Array(250..<800))
        var iterator = Query<IterationPosition>(from: world).makeIterator()
        for _ in 250..<800 { #expect(iterator.next() != nil) }
        #expect(iterator.next() == nil)
        #expect(iterator.next() == nil)
    }

    @Test("Ref writes preserve values and changed versus added ticks across chunks")
    func refWritesAndTicks() {
        let (world, _) = fixture(1_200)
        world.clearTrackers()
        Query<Ref<IterationPosition>, IterationVelocity>(from: world).forEach { position, velocity in
            position.wrappedValue.value += velocity.value
        }

        var values: [Int] = []
        Query<IterationPosition>(from: world).forEach { position in values.append(position.value) }
        #expect(values.sorted() == Array(1...1_200))
        #expect(FilterQuery<IterationPosition, Changed<IterationPosition>>(from: world).count == 1_200)
        #expect(FilterQuery<IterationPosition, Added<IterationPosition>>(from: world).count == 1_200)
        world.clearTrackers()
        #expect(FilterQuery<IterationPosition, Changed<IterationPosition>>(from: world).first == nil)
        #expect(FilterQuery<IterationPosition, Added<IterationPosition>>(from: world).first == nil)
    }

    @Test("Metadata borrows end before the caller mutates the world")
    func mutationBetweenNextCalls() {
        let world = World()
        let entities = (0..<300).map { index in world.spawn { IterationPosition(value: index) } }
        var values: [Int] = []
        Query<IterationPosition>(from: world).forEach { position in
            values.append(position.value)
            if position.value == 0 {
                world.removeEntity(entities[249])
                world.spawn { IterationPosition(value: 999) }
            }
        }
        #expect(values.sorted() == (0..<300).filter { $0 != 249 } + [999])
    }

    @Test("Archetype and row filters agree with the original entity selection")
    func filtersAcrossArchetypes() {
        let (world, entities) = fixture(1_200)
        world.clearTrackers()
        for index in stride(from: 0, to: entities.count, by: 3) {
            world.insert(IterationPosition(value: index), for: entities[index].id)
        }

        var changed: [Int] = []
        FilterQuery<IterationPosition, Changed<IterationPosition>>(from: world).forEach { position in changed.append(position.value) }
        #expect(changed.sorted() == Array(stride(from: 0, to: entities.count, by: 3)))

        var selected: [Int] = []
        FilterQuery<IterationPosition, And<With<IterationTagA>, Changed<IterationPosition>>>(from: world).forEach { position in
            selected.append(position.value)
        }
        #expect(selected.sorted() == (0..<entities.count).filter { $0 % 2 == 1 && $0 % 3 == 0 })
        #expect(FilterQuery<IterationPosition, Without<IterationTagA>>(from: world).count == 600)
        #expect(FilterQuery<IterationPosition, Or<With<IterationTagA>, With<IterationTagB>>>(from: world).count == 900)
    }

    @Test("Custom targets receive the correct Entity and can skip rows")
    func customTargetCompatibility() {
        let world = World()
        let entities = (0..<530).map { index in world.spawn { IterationPosition(value: index) } }
        var values: [Int] = []
        Query<SkippingEntityTarget, IterationPosition>(from: world).forEach { target, position in
            #expect(target.id == entities[position.value].id)
            #expect(target.name == entities[position.value].name)
            values.append(position.value)
        }
        #expect(values == (0..<530).filter { ($0 % 250) % 3 != 1 })
    }

    @Test("Optional Ref targets retain existing matching and mutation behavior")
    func optionalTargets() {
        let (world, _) = fixture(1_200)
        Query<IterationPosition, Ref<IterationVelocity>?>(from: world).forEach { position, velocity in
            velocity?.wrappedValue.value = position.value
        }
        Query<IterationPosition, IterationVelocity>(from: world).forEach { position, velocity in
            #expect(position.value == velocity.value)
        }
        #expect(Query<IterationPosition, IterationTagA?>(from: world).count == 600)
    }
}
