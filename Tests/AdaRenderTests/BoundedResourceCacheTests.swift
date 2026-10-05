import Testing

@testable import AdaRender

@Suite
struct BoundedResourceCacheTests {
    private final class Owner {}

    @Test
    func bindingsReuseValuesRetainOwnersAndRespectTheCapacity() {
        var cache = BoundedResourceCache<Int, Int>(capacity: 2)
        var owner: Owner? = Owner()
        weak var retained = owner
        #expect(cache.value(for: 1, owners: owner.map { [$0] } ?? [], create: { 42 }) == 42)
        owner = nil
        #expect(retained != nil)
        #expect(
            cache.value(
                for: 1,
                owners: [],
                create: {
                    Issue.record("Cache hit rebuilt the binding")
                    return nil
                }
            ) == 42
        )
        #expect(cache.value(for: 2, owners: [], create: { 43 }) == 43)
        #expect(cache.value(for: 3, owners: [], create: { 44 }) == 44)
        #expect(retained == nil)
        #expect(cache.value(for: 1, owners: [], create: { 45 }) == 45)
    }

    @Test
    func failedCreationCanBeRetried() {
        var cache = BoundedResourceCache<Int, Int>(capacity: 1)
        #expect(cache.value(for: 1, owners: [], create: { nil }) == nil)
        #expect(cache.value(for: 1, owners: [], create: { 7 }) == 7)
    }
}
