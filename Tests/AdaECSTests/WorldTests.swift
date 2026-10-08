import Testing
import AdaUtils
@_spi(Internal) @testable import AdaECS
import Math

@Component
struct ComponentA: Equatable, DefaultValue {
    var value: Int

    static let defaultValue: ComponentA = .init(value: 0)
}

@Component
struct ComponentB: Equatable {
    var value: String
}

@Component
struct ComponentC: Equatable { }

@Component(required: [ComponentA.self])
struct ComponentWithRequirement {}

struct TestResource: Resource, Equatable {
    var value: Int
}

@Suite("World Tests")
struct WorldTests {
    let world: World

    init() {
        self.world = World()
    }

    @Test("Get resource")
    func getResource() {
        let resource = Gravity(value: Vector3(0, -9.8, 0))
        world.insertResource(resource)
        let resource2 = world.getResource(Gravity.self)
        #expect(resource == resource2)
    }

    @Test("Get mutable resource")
    func getMutableResource() throws {
        let resource = Gravity(value: Vector3(0, 9.8, 0))
        world.insertResource(resource)
        world.getRefResource(Gravity.self).wrappedValue.value = Vector3(0, -9.8, 0)
        #expect(world.getRefResource(Gravity.self).wrappedValue.value == Vector3(0, -9.8, 0))
    }

    @Test("Spawn empty entity")
    func spawnEmptyEntity() {
        let entity = world.spawn()
        #expect(entity.components.isEmpty)
    }

    @Test("Spawn entity with component")
    func spawnEntityWithComponent() {
        let transform = Transform(position: Vector3(0, 9.8, 0))
        let entity = world.spawn {
            transform
        }
        #expect(entity.components.count == 1)
        #expect(entity.components[Transform.self] == transform)
    }

    @Test("Remove entity")
    func removeEntity() {
        let entity = world.spawn()
        world.removeEntity(entity)
        #expect(world.entities.entities.count == 0)
    }

    @Test("Command spawn")
    func commandSpawn() {
        let transform = Transform(position: Vector3(0, 9.8, 0))
        let commands = world.makeCommands()
        commands.spawn {
            transform
        }
        commands.finish(world)
        world.flush()
        #expect(world.entities.entities.count == 1)
    }

    @Test("Clear world")
    func clearAllWorld() {
        let entityCount = 1000
        for i in 0..<entityCount {
            world.spawn {
                ComponentA(value: i)
                ComponentB(value: "abc")
            }
        }

        let query = Query<ComponentA>()
        query.update(from: world)

        #expect(query.count == entityCount)

        world.clear()

        #expect(world.entities.entities.isEmpty)
        #expect(world.addedEntities.isEmpty)
        #expect(world.removedEntities.isEmpty)

        query.update(from: world)
        #expect(query.count == 0)
    }

    @Test
    func requiredComponentsInitialized() throws {
        world.registerRequiredComponent(ComponentB.self, for: ComponentA.self) {
            .init(value: "test1")
        }

        let ent = world.spawn {
            ComponentA(value: 1)
        }
        let componentA = try #require(ent.components[ComponentA.self])
        let componentB = try #require(ent.components[ComponentB.self])
        #expect(componentA.value == 1)
        #expect(componentB.value == "test1")
    }
}

extension WorldTests {
    @Test("Random Access")
    func randomAccess() {
        let e = world.spawn {
            ComponentA(value: 123)
            ComponentB(value: "abc")
        }

        let f = world.spawn {
            ComponentA(value: 456)
            ComponentB(value: "def")
            ComponentC()
        }

        #expect(world.get(from: e.id) == ComponentA(value: 123))
        #expect(world.get(from: e.id) == ComponentB(value: "abc"))
        #expect(world.get(from: f.id) == ComponentA(value: 456))
        #expect(world.get(from: f.id) == ComponentB(value: "def"))
        #expect(world.get(from: f.id) == ComponentC())

        world.insert(ComponentB(value: "xyz"), for: e.id)
        #expect(world.get(from: e.id) == ComponentB(value: "xyz"))
    }

    @Test("Chunk Creation")
    func chunkCreation() {
        let entityCount = 100
        for i in 0..<entityCount {
            world.spawn {
                ComponentA(value: i)
                ComponentB(value: "abc")
            }
        }

        let query = Query<ComponentA>()
        query.update(from: world)

        #expect(query.count == entityCount)
    }

    @Test("Despawn")
    func despawn() {
        let e = world.spawn {
            ComponentA(value: 123)
            ComponentB(value: "abc")
        }

        let f = world.spawn {
            ComponentA(value: 456)
            ComponentB(value: "def")
        }

        #expect(world.getEntityByID(f.id) != nil)
        #expect(world.getEntityByID(e.id) != nil)

        world.removeEntity(e)

        #expect(world.getEntityByID(e.id) == nil)
        #expect(world.get(from: e.id) as ComponentA? == nil)
        #expect(world.get(from: e.id) as ComponentB? == nil)

        #expect(world.getEntityByID(f.id) != nil)
        #expect(world.get(from: f.id) == ComponentA(value: 456))
        #expect(world.get(from: f.id) == ComponentB(value: "def"))
    }

    @Test
    func `component macro with dependencies`() {
        let entity = world.spawn {
            ComponentWithRequirement()
        }

        #expect(world.getEntityByID(entity.id) != nil)
        #expect(world.get(ComponentWithRequirement.self, from: entity.id) != nil)
        #expect(world.get(ComponentA.self, from: entity.id) == ComponentA(value: 0))
    }

    @Test
    func `insert component adds macro required dependencies`() {
        let entity = world.spawn("Requires")

        entity.components += ComponentWithRequirement()

        #expect(world.get(ComponentWithRequirement.self, from: entity.id) != nil)
        #expect(world.get(ComponentA.self, from: entity.id) == ComponentA(value: 0))
    }

    @Test("Query all")
    func queryAll() {
        let e = world.spawn {
            ComponentB(value: "abc")
            ComponentA(value: 123)
        }

        let f = world.spawn {
            ComponentB(value: "def")
            ComponentA(value: 456)
        }

        let query = Query<Entity, ComponentA, ComponentB>()
        query.update(from: world)

        var results: [(Entity, ComponentA, ComponentB)] = []
        query.forEach { item in
            results.append(item)
        }

        #expect(results.count == 2)

        // The order is not guaranteed, so we need to check for existence of both.
        let expected: [(Entity, ComponentA, ComponentB)] = [
            (e, ComponentA(value: 123), ComponentB(value: "abc")),
            (f, ComponentA(value: 456), ComponentB(value: "def"))
        ]

        for expectedItem in expected {
            #expect(results.contains(where: { $0.0.id == expectedItem.0.id && $0.1 == expectedItem.1 && $0.2 == expectedItem.2 }))
        }
    }

    @Test("Query filter with")
    func queryFilterWith() {
        world.spawn {
            ComponentA(value: 123)
            ComponentB(value: "a")
        }
        world.spawn {
            ComponentA(value: 456)
        }

        let query = world.performQuery(FilterQuery<ComponentA, With<ComponentB>>())
        let results = query.map { $0 }

        #expect(results.count == 1)
        #expect(results.first == ComponentA(value: 123))
    }

    @Test("Query filter without")
    func queryFilterWithout() {
        world.spawn {
            ComponentA(value: 123)
            ComponentB(value: "a")
        }
        world.spawn {
            ComponentA(value: 456)
        }

        let query = world.performQuery(FilterQuery<ComponentA, Without<ComponentB>>())
        let results = query.map { $0 }

        #expect(results.count == 1)
        #expect(results.first == ComponentA(value: 456))
    }

    @Test("Add and remove components")
    func addRemoveComponents() {
        let e = world.spawn {
            ComponentA(value: 1)
            ComponentB(value: "a")
        }

        // Check initial state
        #expect(world.has(ComponentA.self, in: e.id))
        #expect(world.has(ComponentB.self, in: e.id))
        #expect(!world.has(ComponentC.self, in: e.id))

        // Add ComponentC
        world.insert(ComponentC(), for: e.id)
        #expect(world.has(ComponentC.self, in: e.id))

        // Remove ComponentA
        world.remove(ComponentA.self, from: e.id)
        #expect(!world.has(ComponentA.self, in: e.id))
        #expect(world.get(from: e.id) as ComponentA? == nil)
        #expect(world.has(ComponentB.self, in: e.id))
        #expect(world.has(ComponentC.self, in: e.id))
    }

    @Test("Query optional component")
    func queryOptionalComponent() {
        let e = world.spawn {
            ComponentA(value: 123)
        }

        let f = world.spawn {
            ComponentA(value: 456)
            ComponentB(value: "b")
        }

        let query = FilterQuery<Entity, ComponentA, Optional<ComponentB>, NoFilter>()
        query.update(from: world)

        var results: [(Entity.ID, ComponentA, Optional<ComponentB>)] = []
        query.forEach { entity, a, b in
            results.append((entity.id, a, b))
        }
        // We skipped optional components
        #expect(results.count == 1)

        let resultE = results.first(where: { $0.0 == e.id })
        #expect(resultE == nil)

        let resultF = results.first(where: { $0.0 == f.id })
        #expect(resultF?.1 == ComponentA(value: 456))
        #expect(resultF?.2 == ComponentB(value: "b"))
    }

    @Test("Spawn Batch")
    func spawnBatch() {
        let entityCount = 1000
        for i in 0..<entityCount {
            world.spawn {
                ComponentA(value: i)
                ComponentB(value: "abc")
            }
        }

        let query = Query<ComponentA>()
        query.update(from: world)

        #expect(query.count == entityCount)

        var sum = 0
        query.forEach { a in
            sum += a.value
        }

        let expectedSum = (0..<entityCount).reduce(0, +)
        #expect(sum == expectedSum)
    }

    @Test("Remove Missing Component")
    func removeMissingComponent() {
        let e = world.spawn {
            ComponentA(value: 123)
        }

        // This should not crash or fail.
        world.remove(ComponentB.self, from: e.id)
        #expect(world.has(ComponentA.self, in: e.id))
        #expect(!world.has(ComponentB.self, in: e.id))
    }

    @Test("Resource Management")
    func resourceManagement() {
        #expect(world.getResource(TestResource.self) == nil)
        world.insertResource(TestResource(value: 123))

        #expect(world.getResource(TestResource.self) != nil)
        #expect(world.getResource(TestResource.self)?.value == 123)

        let mutableResource = world.getRefResource(TestResource.self)
        mutableResource.wrappedValue.value = 456

        #expect(world.getResource(TestResource.self)?.value == 456)

        world.removeResource(TestResource.self)
        #expect(world.getResource(TestResource.self) == nil)
    }

    @Test("Added Tracking")
    func addedTracking() {
        let e = world.spawn { ComponentA(value: 123) }

        #expect(world.addedEntities.contains(e.id))
        #expect(world.addedEntities.count == 1)

        world.clearTrackers()

        #expect(world.addedEntities.isEmpty)
    }

    @Test("Changed Tracking")
    func changedTracking() {
        let e1 = world.spawn { ComponentA(value: 0) }
        let e2 = world.spawn { ComponentA(value: 0) }

        world.clearTrackers()

        let query = Query<Entity, Ref<ComponentA>>()
        query.update(from: world)

        for (index, item) in query.enumerated() {
            if index % 2 == 0 {
                item.1.wrappedValue.value += 1
                #expect(item.1.isChanged)
            } else {
                #expect(!item.1.isChanged)
            }
        }

        let changedQuery = world.performQuery(FilterQuery<Entity, Changed<ComponentA>>())
        let changedEntities = Set(changedQuery.map { $0.id })

        #expect(changedEntities.count == 1)
        #expect(changedEntities.contains(e1.id))
        #expect(!changedEntities.contains(e2.id))

        // Ensure moving archetypes preserves change state
        world.insert(ComponentB(value: "moved"), for: e1.id)

        let changedQueryAfterMove = world.performQuery(FilterQuery<Entity, Changed<ComponentA>>())
        let changedEntitiesAfterMove = Set(changedQueryAfterMove.map { $0.id })

        #expect(changedEntitiesAfterMove.count == 1)
        #expect(changedEntitiesAfterMove.contains(e1.id))
    }

    @Test
    func requiredComponent() {
        world.registerRequiredComponent(RequiredComponentForA.self, for: ComponentA.self) {
            RequiredComponentForA(someValue: "some value")
        }

        let entity = world.spawn("Some entity") {
            ComponentB(value: "value")
        }

        #expect(entity.components[ComponentB.self]?.value == "value")
        #expect(entity.components[ComponentA.self] == nil)
        #expect(entity.components[RequiredComponentForA.self] == nil)

        entity.components += ComponentA(value: 1)

        #expect(entity.components[ComponentA.self]?.value == 1)
        #expect(entity.components[RequiredComponentForA.self]?.someValue == "some value")
    }
}

extension WorldTests {
    @Test
    func `when entities move to new archetype inserted component stored correctly`() {
        let red = world.spawn("Red") {
            Transform(position: Vector3(-0.5, 0, 0))
        }
        let blue = world.spawn("Blue") {
            Transform(position: Vector3(0, 0, 0.1))
        }
        let yellow = world.spawn("Yellow") {
            Transform(position: Vector3(0.5, 0, 0.2))
        }

        let commands = world.makeCommands()
        commands.entity(red.id)
            .insert(ComponentB(value: red.name))
        commands.entity(blue.id)
            .insert(ComponentB(value: blue.name))
        commands.entity(yellow.id)
            .insert(ComponentB(value: yellow.name))

        commands.finish(world)

        #expect(world.get(ComponentB.self, from: red.id)!.value == red.name)
        #expect(world.get(ComponentB.self, from: blue.id)!.value == blue.name)
        #expect(world.get(ComponentB.self, from: yellow.id)!.value == yellow.name)
    }

    @Test
    func `moving entity across archetypes preserves locations when archetype and chunk swaps differ`() {
        var entities: [Entity] = []
        entities.reserveCapacity(300)

        for index in 0..<300 {
            entities.append(
                world.spawn("Entity \(index)") {
                    ComponentA(value: index)
                }
            )
        }

        let moved = entities[0]
        let chunkSwapped = entities[249]
        let archetypeSwapped = entities[299]

        world.insert(ComponentB(value: "moved"), for: moved.id)

        #expect(world.get(ComponentA.self, from: moved.id)?.value == 0)
        #expect(world.get(ComponentB.self, from: moved.id)?.value == "moved")
        #expect(world.get(ComponentA.self, from: chunkSwapped.id)?.value == 249)
        #expect(world.get(ComponentA.self, from: archetypeSwapped.id)?.value == 299)

        let query = world.performQuery(Query<Entity, ComponentA>())
        let valuesByEntity = Dictionary(uniqueKeysWithValues: query.map { entity, component in
            (entity.id, component.value)
        })

        #expect(valuesByEntity[moved.id] == 0)
        #expect(valuesByEntity[chunkSwapped.id] == 249)
        #expect(valuesByEntity[archetypeSwapped.id] == 299)
    }
}

@Component
struct RequiredComponentForA {
    let someValue: String
}
