@_spi(Scripting) @testable import AdaECS
import AdaUtils
import Testing

struct LifetimeResource: Resource {
    var value: Int
    let tracker: DeinitTracker

    init(_ id: String, value: Int = 0, counter: DeinitCounter) {
        self.value = value
        self.tracker = DeinitTracker(id: id, counter: counter)
    }
}

final class LifetimeClassResource: Resource {
    let tracker: DeinitTracker
    init(_ id: String, counter: DeinitCounter) { tracker = DeinitTracker(id: id, counter: counter) }
}

@Suite("Resource lifetime")
struct ResourceLifetimeTests {
    @Test("Replacement releases the old resource and removal releases the new one")
    func replacementAndRemoval() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("old", counter: counter))
        world.insertResource(LifetimeResource("new", counter: counter))
        #expect(counter.deinitializedIds == ["old"])
        world.removeResource(LifetimeResource.self)
        #expect(counter.deinitializedIds.sorted() == ["new", "old"])
        #expect(world.getResource(LifetimeResource.self) == nil)
    }

    @Test("Type-erased removal destroys a class resource once")
    func erasedRemoval() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeClassResource("class", counter: counter))
        let type: any Resource.Type = LifetimeClassResource.self
        world.removeResource(type)
        world.removeResource(type)
        #expect(counter.deinitializedIds == ["class"])
    }

    @Test("Repeated clearResources releases resources while clear preserves them")
    func clearResources() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("struct", counter: counter))
        world.insertResource(LifetimeClassResource("class", counter: counter))
        world.clear()
        #expect(counter.deinitializedIds.isEmpty)
        world.clearResources()
        world.clearResources()
        #expect(counter.deinitializedIds.sorted() == ["class", "struct"])
    }

    @Test("World teardown releases resources without an explicit clear")
    func worldTeardown() {
        let counter = DeinitCounter()
        func makeWorld() -> World {
            let world = World()
            world.insertResource(LifetimeResource("world", counter: counter))
            world.insertResource(LifetimeClassResource("worldClass", counter: counter))
            return world
        }
        var world: World? = makeWorld()
        weak var weakWorld = world
        world = nil
        #expect(weakWorld == nil)
        #expect(counter.deinitializedIds.sorted() == ["world", "worldClass"])
    }

    @Test("Resource metadata snapshots share cleanup until the last owner is dropped")
    func metadataSnapshot() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("snapshot", counter: counter))
        var snapshot: World.Resources? = world.resources
        world.clearResources()
        #expect(world.getResource(LifetimeResource.self) == nil)
        #expect(snapshot?.getResource(LifetimeResource.self)?.tracker.id == "snapshot")
        withExtendedLifetime(snapshot) {
            #expect(counter.deinitializedIds.isEmpty)
        }
        snapshot = nil
        #expect(counter.deinitializedIds == ["snapshot"])
    }

    @Test("A resource Ref keeps old storage until the last view is released")
    func refLease() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("viewed", counter: counter))
        var ref: Ref<LifetimeResource>? = world.getRefResource(LifetimeResource.self)
        #expect(ref != nil)
        world.insertResource(LifetimeResource("current", counter: counter))
        #expect(counter.deinitializedIds.isEmpty)
        #expect(ref?.wrappedValue.tracker.id == "viewed")
        ref?.wrappedValue.value = 42
        #expect(ref?.wrappedValue.value == 42)
        #expect(world.getResource(LifetimeResource.self)?.value == 0)
        ref = nil
        #expect(counter.deinitializedIds == ["viewed"])
        world.clearResources()
        #expect(counter.deinitializedIds.sorted() == ["current", "viewed"])
    }

    @Test("Copied resource refs survive removal and release only after the last copy")
    func copiedRefs() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("copies", value: 7, counter: counter))
        var first: Ref<LifetimeResource>? = world.getRefResource(LifetimeResource.self)
        var second = first
        world.removeResource(LifetimeResource.self)
        first = nil
        #expect(counter.deinitializedIds.isEmpty)
        #expect(second?.wrappedValue.value == 7)
        second?.wrappedValue.value = 8
        #expect(second?.wrappedValue.value == 8)
        second = nil
        #expect(counter.deinitializedIds == ["copies"])
    }

    @Test("An initialized resource ref survives World teardown without retaining World")
    func initializedRefWorldTeardown() {
        let counter = DeinitCounter()
        var world: World? = World()
        weak var weakWorld = world
        var ref = world?.getOrInitRefResource(LifetimeResource.self) {
            LifetimeResource("initialized", value: 10, counter: counter)
        }
        world = nil
        #expect(weakWorld == nil)
        #expect(counter.deinitializedIds.isEmpty)
        #expect(ref?.wrappedValue.value == 10)
        ref?.wrappedValue.value += 1
        #expect(ref?.wrappedValue.value == 11)
        ref = nil
        #expect(counter.deinitializedIds == ["initialized"])
    }

    @Test("ResMut retains a removed resource until its wrapper is released")
    func mutableParameterLease() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("mutable", counter: counter))
        var resource: ResMut<LifetimeResource>? = ResMut(from: world)
        world.clearResources()
        resource?.wrappedValue.value = 12
        #expect(resource?.wrappedValue.value == 12)
        #expect(counter.deinitializedIds.isEmpty)
        resource = nil
        #expect(counter.deinitializedIds == ["mutable"])
    }

    @Test("DynamicResource retains removed storage through reads, writes and finish")
    func dynamicParameterLease() {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("dynamic", value: 1, counter: counter))
        let resource = DynamicResource(resourceType: LifetimeResource.self, isOptional: false, writable: true)
        resource.update(from: world)
        world.clearResources()
        let field = unsafe Self.valueField()
        #expect(resource.read(field: field) == .int(1))
        #expect(resource.write(field: field, value: .int(2)))
        #expect(resource.read(field: field) == .int(2))
        #expect(counter.deinitializedIds.isEmpty)
        resource.finish(world)
        #expect(!resource.isAvailable)
        #expect(resource.read(field: field) == nil)
        #expect(counter.deinitializedIds == ["dynamic"])
    }

    @Test("Reflected World callbacks keep removed storage alive until access returns", arguments: [false, true])
    func reflectedCallbackLease(write: Bool) {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("reflection", value: 3, counter: counter))
        let field = unsafe Self.valueField {
            world.removeResource(LifetimeResource.self)
            #expect(counter.deinitializedIds.isEmpty)
        }
        if write {
            #expect(world.writeResourceField(type: LifetimeResource.self, field: field, value: .int(4)))
        } else {
            #expect(world.readResourceField(type: LifetimeResource.self, field: field) == .int(3))
        }
        #expect(counter.deinitializedIds == ["reflection"])
    }

    @Test("Dynamic callbacks can finish their own parameter without invalidating the pointer", arguments: [false, true])
    func dynamicCallbackLease(write: Bool) {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("callback", value: 5, counter: counter))
        let resource = DynamicResource(resourceType: LifetimeResource.self, isOptional: false, writable: true)
        resource.update(from: world)
        world.clearResources()
        let field = unsafe Self.valueField {
            resource.finish(world)
            #expect(counter.deinitializedIds.isEmpty)
        }
        if write {
            #expect(resource.write(field: field, value: .int(6)))
        } else {
            #expect(resource.read(field: field) == .int(5))
        }
        #expect(!resource.isAvailable)
        #expect(counter.deinitializedIds == ["callback"])
    }

    @Test("Event update callbacks retain resource storage through self-removal")
    func eventCallbackLease() async throws {
        let counter = DeinitCounter()
        let world = World()
        world.insertResource(LifetimeResource("event", value: 9, counter: counter))
        let resourceId = try #require(world.resources.getResourceId(for: LifetimeResource.self))
        let handle = unsafe HandledEvents.Handle(resourceId: resourceId) { [weak world] pointer in
            world?.removeResource(LifetimeResource.self)
            #expect(counter.deinitializedIds.isEmpty)
            #expect(unsafe pointer.assumingMemoryBound(to: LifetimeResource.self).pointee.value == 9)
        }
        world.insertResource(HandledEvents(handledEvents: [handle]))
        world.addSystem(EventsUpdateSystem.self)
        await world.runScheduler(.update)
        #expect(world.getResource(LifetimeResource.self) == nil)
        #expect(counter.deinitializedIds == ["event"])
    }

    @unsafe
    private static func valueField(beforeAccess: @escaping @Sendable () -> Void = {}) -> ReflectedComponentField {
        unsafe ReflectedComponentField(
            key: "value",
            label: "Value",
            kind: .int,
            isWritable: true,
            read: { _ in nil },
            write: { _, _ in nil },
            readPointer: { pointer in
                beforeAccess()
                return unsafe .int(pointer.assumingMemoryBound(to: LifetimeResource.self).pointee.value)
            },
            writePointer: { pointer, value in
                guard case let .int(value) = value else {
                    return false
                }
                beforeAccess()
                unsafe pointer.assumingMemoryBound(to: LifetimeResource.self).pointee.value = value
                return true
            }
        )
    }

    @Test("Blob teardown destroys initialized slots and ignores removed slots")
    func blobFinalOwner() {
        let counter = DeinitCounter()
        func allocate() -> BlobArray {
            let blob = unsafe BlobArray(count: 4, of: TrackableComponent.self) { pointer, count in
                unsafe pointer.baseAddress?.assumingMemoryBound(to: TrackableComponent.self).deinitialize(count: count)
            }
            blob.insert(TrackableComponent(id: "removed", counter: counter), at: 0)
            blob.insert(TrackableComponent(id: "kept", counter: counter), at: 2)
            blob.remove(at: 0)
            return blob
        }
        var blob: BlobArray? = allocate()
        #expect(blob?.count == 4)
        #expect(counter.deinitializedIds == ["removed"])
        blob = nil
        #expect(counter.deinitializedIds.sorted() == ["kept", "removed"])
    }

    @Test("Reallocation transfers cleanup ownership even while old allocation aliases exist")
    func transferredBufferOwnership() {
        let counter = DeinitCounter()
        func run() {
            var blob = unsafe BlobArray(count: 2, of: TrackableComponent.self) { pointer, count in
                unsafe pointer.baseAddress?.assumingMemoryBound(to: TrackableComponent.self).deinitialize(count: count)
            }
            blob.insert(TrackableComponent(id: "kept", counter: counter), at: 0)
            blob.insert(TrackableComponent(id: "shrunk", counter: counter), at: 1)
            let alias = blob
            blob.realloc(4)
            blob.realloc(1)
            #expect(counter.deinitializedIds == ["shrunk"])
            withExtendedLifetime(alias) {}
        }
        run()
        #expect(counter.deinitializedIds.sorted() == ["kept", "shrunk"])
    }

    @Test("World teardown also destroys live component columns")
    func componentTeardown() {
        let counter = DeinitCounter()
        func allocate() {
            let world = World()
            _ = world.spawn { TrackableComponent(id: "component", counter: counter) }
        }
        allocate()
        #expect(counter.deinitializedIds == ["component"])
    }
}
