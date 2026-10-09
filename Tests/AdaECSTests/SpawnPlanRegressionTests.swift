import AdaECS
import AdaUtils
import Synchronization
import Testing

@Component
struct SpawnCacheParent { var value: Int }
@Component
struct SpawnCacheSecondParent {}
@Component
struct SpawnCacheChild: DefaultValue {
    var value: Int
    static var defaultValue: Self { Self(value: 43) }
}
@Component
struct SpawnCacheOther: DefaultValue {
    var value: Int
    static var defaultValue: Self { Self(value: 87) }
}
@Component(required: [SpawnCacheChild.self])
struct SpawnCacheStaticParent {}

final class SpawnSequence: Sendable {
    private let value = Mutex<Int>(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
    func reset() { value.withLock { $0 = 0 } }
}

struct SpawnCacheDynamicParent: Component {
    static let calls = SpawnSequence()
    static var requiredComponents: RequiredComponents {
        switch calls.next() % 3 {
        case 1: RequiredComponents(components: [SpawnCacheChild.self])
        case 2: RequiredComponents(components: [SpawnCacheOther.self])
        default: RequiredComponents(components: [])
        }
    }
}

final class SpawnEventRecords: Sendable {
    private let values = Mutex<[Int]>([])
    func append(_ value: Int) { values.withLock { $0.append(value) } }
    var snapshot: [Int] { values.withLock { $0 } }
}

@Suite("Spawn plan regressions")
struct SpawnPlanRegressionTests {
    private func descriptor(_ name: String, value: Int) -> RuntimeComponentDescriptor {
        RuntimeComponentDescriptor(stableID: "tests.spawn.cache.\(name)", name: name, fieldNames: ["value"], defaultValues: [.int(value)])
    }

    @Test("Every spawn invokes factories and owns its own constructed payload")
    func factoryValuesAndLifetime() {
        let world = World()
        let sequence = SpawnSequence()
        let destroyed = DeinitCounter()
        world.registerRequiredComponent(TrackableComponent.self, for: SpawnCacheParent.self) {
            TrackableComponent(id: "\(sequence.next())", counter: destroyed)
        }
        for index in 1...64 {
            let entity = world.spawn { SpawnCacheParent(value: index) }
            #expect(world.get(TrackableComponent.self, from: entity.id)?.id == "\(index)")
        }
        #expect(sequence.count == 64)
        #expect(destroyed.deinitializedIds.isEmpty)
        world.clear()
        #expect(Set(destroyed.deinitializedIds) == Set((1...64).map(String.init)))
        #expect(destroyed.deinitializedIds.count == 64)
    }

    @Test("Registering and replacing requirements updates warmed signatures")
    func registrationInvalidatesPlan() {
        let world = World()
        _ = world.spawn { SpawnCacheParent(value: 0) }
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 1) }
        let first = world.spawn { SpawnCacheParent(value: 1) }
        #expect(world.get(SpawnCacheChild.self, from: first.id)?.value == 1)
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 2) }
        world.registerRequiredComponent(SpawnCacheOther.self, for: SpawnCacheParent.self) { SpawnCacheOther(value: 3) }
        for index in 2...4 {
            let entity = world.spawn { SpawnCacheParent(value: index) }
            #expect(world.get(SpawnCacheChild.self, from: entity.id)?.value == 2)
            #expect(world.get(SpawnCacheOther.self, from: entity.id)?.value == 3)
        }
        #expect(world.get(SpawnCacheChild.self, from: first.id)?.value == 1)
        #expect(world.get(SpawnCacheOther.self, from: first.id) == nil)
    }

    @Test("Worlds, copies and clear preserve independent constructor registrations")
    func worldLocalPlans() {
        let first = World()
        let second = World()
        first.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 1) }
        second.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 2) }
        for _ in 0..<3 {
            let a = first.spawn { SpawnCacheParent(value: 0) }
            let b = second.spawn { SpawnCacheParent(value: 0) }
            #expect(first.get(SpawnCacheChild.self, from: a.id)?.value == 1)
            #expect(second.get(SpawnCacheChild.self, from: b.id)?.value == 2)
        }
        let copy = first.copy()
        copy.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 3) }
        let copied = copy.spawn { SpawnCacheParent(value: 0) }
        #expect(copy.get(SpawnCacheChild.self, from: copied.id)?.value == 3)
        first.clear()
        let recreated = first.spawn { SpawnCacheParent(value: 0) }
        #expect(first.get(SpawnCacheChild.self, from: recreated.id)?.value == 1)
    }

    @Test("Computed type requirements are evaluated on every spawn")
    func dynamicTypeRequirements() {
        SpawnCacheDynamicParent.calls.reset()
        defer { SpawnCacheDynamicParent.calls.reset() }
        let world = World()
        for index in 1...6 {
            let entity = world.spawn { SpawnCacheDynamicParent() }
            #expect(world.has(SpawnCacheChild.self, in: entity.id) == (index % 3 == 1))
            #expect(world.has(SpawnCacheOther.self, in: entity.id) == (index % 3 == 2))
        }
        #expect(SpawnCacheDynamicParent.calls.count == 6)
    }

    @Test("Logical runtime schemas have distinct plans and registration invalidation")
    func runtimeSchemas() {
        let world = World()
        let health = descriptor("health", value: 3)
        let score = descriptor("score", value: 7)
        world.registerRuntimeComponent(health)
        world.registerRuntimeComponent(score)
        for _ in 0..<3 {
            let both = world.spawn { health.makeDefault(); score.makeDefault() }
            #expect(world.getRuntimeComponent(health.componentID, from: both.id)?.values == [.int(3)])
            #expect(world.getRuntimeComponent(score.componentID, from: both.id)?.values == [.int(7)])
        }
        world.registerRequiredComponent(SpawnCacheChild.self, forRuntimeComponent: health.componentID) { SpawnCacheChild(value: 9) }
        let a = world.spawn { health.makeDefault() }
        let b = world.spawn { score.makeDefault() }
        #expect(world.get(SpawnCacheChild.self, from: a.id)?.value == 9)
        #expect(world.get(SpawnCacheChild.self, from: b.id) == nil)
    }

    @Test("A factory may return a different logical runtime type on each invocation")
    func varyingFactoryTopology() {
        let world = World()
        let a = descriptor("factoryA", value: 10)
        let b = descriptor("factoryB", value: 20)
        let sequence = SpawnSequence()
        world.registerRequiredComponent(RuntimeComponentPayload.self, for: SpawnCacheParent.self) {
            sequence.next() % 2 == 1 ? a.makeDefault() : b.makeDefault()
        }
        for index in 1...6 {
            let entity = world.spawn { SpawnCacheParent(value: index) }
            let expected = index % 2 == 1 ? a : b
            let absent = index % 2 == 1 ? b : a
            #expect(world.getRuntimeComponent(expected.componentID, from: entity.id)?.values == expected.defaultValues)
            #expect(world.getRuntimeComponent(absent.componentID, from: entity.id) == nil)
        }
        #expect(sequence.count == 6)
    }

    @Test("A factory registration change affects the next input component immediately")
    func reentrantRegistration() {
        let world = World()
        let sequence = SpawnSequence()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) {
            let call = sequence.next()
            if call == 1 || call == 3 {
                world.registerRequiredComponent(SpawnCacheOther.self, for: SpawnCacheSecondParent.self) {
                    SpawnCacheOther(value: call)
                }
            }
            return SpawnCacheChild(value: call)
        }
        for index in 1...4 {
            let entity = world.spawn { SpawnCacheParent(value: index); SpawnCacheSecondParent() }
            #expect(world.get(SpawnCacheChild.self, from: entity.id)?.value == index)
            #expect(world.get(SpawnCacheOther.self, from: entity.id)?.value == (index < 3 ? 1 : 3))
        }
    }

    @Test("Input order and explicit-value precedence stay unchanged")
    func explicitValuesAndOrdering() {
        let world = World()
        let sequence = SpawnSequence()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) {
            SpawnCacheChild(value: sequence.next())
        }
        for _ in 0..<3 {
            let explicitLast = world.spawn { SpawnCacheParent(value: 0); SpawnCacheChild(value: 99) }
            #expect(world.get(SpawnCacheChild.self, from: explicitLast.id)?.value == 99)
            let requiredLast = world.spawn { SpawnCacheChild(value: 99); SpawnCacheParent(value: 0) }
            #expect(world.get(SpawnCacheChild.self, from: requiredLast.id)?.value == sequence.count)
        }
        #expect(sequence.count == 6)
        let defaults = world.spawn { SpawnCacheStaticParent() }
        #expect(world.get(SpawnCacheChild.self, from: defaults.id)?.value == 43)
    }

    @Test("A required factory can spawn recursively without borrowing the cache across callbacks")
    func reentrantSpawn() {
        let world = World()
        let sequence = SpawnSequence()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) {
            let call = sequence.next()
            if call == 1 {
                _ = world.spawn { SpawnCacheParent(value: 2) }
            }
            return SpawnCacheChild(value: call)
        }
        let outer = world.spawn { SpawnCacheParent(value: 1) }
        #expect(world.get(SpawnCacheChild.self, from: outer.id)?.value == 1)
        var values: [Int] = []
        Query<SpawnCacheChild>(from: world).forEach { child in values.append(child.value) }
        #expect(values.sorted() == [1, 2])
        let warmed = world.spawn { SpawnCacheParent(value: 3) }
        #expect(world.get(SpawnCacheChild.self, from: warmed.id)?.value == 3)
    }

    @Test("Replacing a factory releases captures retained by warmed plans")
    func factoryCaptureLifetime() {
        let world = World()
        let destroyed = DeinitCounter()
        func registerCapturedFactory() {
            let marker = DeinitTracker(id: "factory", counter: destroyed)
            world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) {
                SpawnCacheChild(value: marker.id.count)
            }
        }
        registerCapturedFactory()
        _ = world.spawn { SpawnCacheParent(value: 0) }
        #expect(destroyed.deinitializedIds.isEmpty)
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: 2) }
        #expect(destroyed.deinitializedIds == ["factory"])
    }

    @Test("DidAddEntity observes initialized components, locations and current ticks")
    func eventsAndTicks() throws {
        let world = World()
        let sequence = SpawnSequence()
        let observed = SpawnEventRecords()
        world.registerRequiredComponent(SpawnCacheChild.self, for: SpawnCacheParent.self) { SpawnCacheChild(value: sequence.next()) }
        let subscription = world.subscribe(to: WorldEvents.DidAddEntity.self, on: world) { event in
            #expect(event.entity.world === world)
            observed.append(world.get(SpawnCacheChild.self, from: event.entity.id)?.value ?? -1)
        }
        defer { subscription.cancel() }
        for index in 1...520 {
            let entity = world.spawn { SpawnCacheParent(value: index) }
            let location = try #require(world.entities.entities[entity.id])
            let ticks = try #require(world.archetypes.archetypes[location.archetypeId].chunks[location.chunkIndex].getComponentTicksSlice(for: SpawnCacheChild.self))
            #expect(unsafe ticks.added[location.chunkRow] == world.currentTick)
            #expect(unsafe ticks.changed[location.chunkRow] == world.currentTick)
        }
        #expect(observed.snapshot == Array(1...520))
    }

    @Test("Many signatures and empty spawns remain valid after cache churn")
    func cacheChurn() {
        let world = World()
        for index in 0..<300 {
            let schema = descriptor("churn\(index)", value: index)
            let entity = world.spawn { schema.makeDefault() }
            #expect(world.getRuntimeComponent(schema.componentID, from: entity.id)?.values == [.int(index)])
        }
        let first = descriptor("churn0", value: 42)
        let again = world.spawn { first.makeDefault() }
        #expect(world.getRuntimeComponent(first.componentID, from: again.id)?.values == [.int(42)])
        for _ in 0..<3 { #expect(world.spawn().components.isEmpty) }
    }
}
