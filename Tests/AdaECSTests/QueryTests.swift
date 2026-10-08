import Testing
@_spi(Internal) @testable import AdaECS
import Math

@Suite("Query tests")
struct QueryTests {
    @Test("Query fetch components")
    func queryFetchComponents() {
        let world = World()

        for _ in 0..<10 {
            world.spawn {
                Transform()
                Velocity()
            }
        }
        let query = Query<Entity, Transform, Velocity>()
        query.update(from: world)

        #expect(query.wrappedValue.count == 10)
        query.wrappedValue.forEach { entity, transform, velocity in
            #expect(transform.position == .zero)
            #expect(velocity.velocity == .zero)
        }
    }

    @Test("Query with ref components")
    func queryWithRefComponents() {
        let world = World()
        
        for i in 0..<5 {
            world.spawn {
                Transform(position: [Float(i), 0, 0])
            }
        }
        
        let query = Query<Entity, Ref<Transform>>()
        query.update(from: world)
        
        #expect(query.wrappedValue.count == 5)
        
        // Test we can modify components through refs
        query.wrappedValue.forEach { entity, transform in
            transform.wrappedValue.position.y = 10
        }
        
        query.wrappedValue.forEach { entity, transform in
            #expect(transform.wrappedValue.position.y == 10)
        }
    }

    @Test("Parallel query forwards query target packs")
    func parallelQueryForwardsQueryTargetPacks() async {
        let world = World()

        for index in 0..<64 {
            world.spawn {
                Transform(position: [Float(index), 0, 0])
            }
        }

        let query = Query<Entity, Transform>()
        query.update(from: world)

        let positions = await query.parallel(batchSize: 1).map { _, transform in
            transform.position.x
        }

        #expect(positions.sorted() == (0..<64).map(Float.init))
    }
    
    @Test("Query with where clause")
    func queryWithWhereClause() {
        let world = World()
        
        // Add entities with different component combinations
        for i in 0..<10 {
            world.spawn {
                Transform()
                if i % 2 == 0 {
                    Velocity()
                }
            }
        }
        
        // Query only entities with both Transform and Velocity
        let query = Query<Entity, Transform, Velocity>()
        query.update(from: world)
        
        #expect(query.wrappedValue.count == 5)
    }
    
    @Test("Query updates when entities change")
    func queryUpdatesWithEntityChanges() async {
        let world = World()
        
        let query = Query<Entity, Transform>()
        query.update(from: world)
        #expect(query.wrappedValue.count == 0)

        // Add entity
        let entity = world.spawn {
            Transform()
        }

        query.update(from: world)
        #expect(query.wrappedValue.count == 1)
        
        // Remove component
        entity.components.remove(Transform.self)
        await world.runScheduler(.update)

        query.update(from: world)
        #expect(query.wrappedValue.count == 0)
    }

    @Test("Query with optional components")
    func queryWithOptionalComponents() async {
        let world = World()

        let entity = world.spawn {
            Transform()
        }
        
        let query = Query<Entity, Optional<Transform>, Velocity>()
        query.update(from: world)
        #expect(query.wrappedValue.count == 0)
        entity.components += Velocity()
        query.update(from: world)
        #expect(query.wrappedValue.count == 1)
    }

    @Test("FilterQuery with With filter")
    func filterQueryWithWithFilter() async {
        let world = World()
        for i in 0..<5 {
            world.spawn {
                if i % 2 == 0 {
                    Transform()
                }
            }
        }
        let query = world.performQuery(FilterQuery<Entity, With<Transform>>())
        #expect(query.count == 3)
    }

    @Test("FilterQuery with WithOut filter")
    func filterQueryWithWithOutFilter() {
        let world = World()
        for i in 0..<5 {
            world.spawn {
                if i % 2 == 0 {
                    Transform()
                }
            }
        }
        let query = world.performQuery(FilterQuery<Entity, Without<Transform>>())
        #expect(query.count == 2)
    }

    @Test("FilterQuery with And filter")
    func filterQueryWithAndFilter() async {
        let world = World()
        for i in 0..<6 {
            world.spawn {
                if i % 2 == 0 {
                    Transform()
                }
                if i % 3 == 0 {
                    Velocity()
                }
            }
        }
        await world.runScheduler(.update)
        let query = world.performQuery(FilterQuery<Entity, And<With<Transform>, With<Velocity>>>())
        // Only entities with both Transform and Velocity (i == 0)
        #expect(query.count == 1)
    }

    @Test("FilterQuery with Or filter")
    func filterQueryWithOrFilter() {
        let world = World()
        for i in 0..<6 {
            world.spawn {
                if i % 2 == 0 {
                    Transform()
                }
                if i % 3 == 0 {
                    Velocity()
                }
            }
        }
        let query = world.performQuery(FilterQuery<Entity, Or<With<Transform>, With<Velocity>>>())
        // Entities with either Transform or Velocity (i == 0,1,2,3,4,5 except i==1,4)
        #expect(query.count == 4)
    }

    @Test("FilterQuery with NoFilter")
    func filterQueryWithNoFilter() {
        let world = World()
        for _ in 0..<4 {
            world.spawn {
                Transform()
            }
        }
        let query = Query<Entity>()
        query.update(from: world)
        #expect(query.wrappedValue.count == 4)
    }
}
