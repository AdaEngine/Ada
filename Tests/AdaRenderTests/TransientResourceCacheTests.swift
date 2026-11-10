@testable import AdaRender
import Testing

@Suite
struct TransientResourceCacheTests {
    private final class Owner {}

    @Test
    func hitsDoNotRebuildOrCollectOwners() {
        var cache = TransientResourceCache<Int, Int>(maximumAge: 4)
        #expect(cache.value(for: 1, epoch: 0, owners: { [] }, create: { 10 }) == 10)
        let hit = cache.value(for: 1, epoch: 3, owners: {
            Issue.record("A cache hit collected owners")
            return []
        }, create: {
            Issue.record("A cache hit rebuilt the value")
            return nil
        })
        #expect(hit == 10)
    }

    @Test
    func entriesUnusedForLongerThanTheMaximumAgeReleaseTheirOwners() {
        var cache = TransientResourceCache<Int, Int>(maximumAge: 4)
        var attachment: Owner? = Owner()
        weak var retained = attachment
        _ = cache.value(for: 1, epoch: 0, owners: { attachment.map { [$0] } ?? [] }, create: { 1 })
        attachment = nil
        // Still used within the age: kept alive.
        _ = cache.value(for: 1, epoch: 4, owners: { [] }, create: { 2 })
        _ = cache.value(for: 2, epoch: 8, owners: { [] }, create: { 3 })
        #expect(retained != nil)
        #expect(cache.value(for: 2, epoch: 9, owners: { [] }, create: { 4 }) == 3)
        // Key 1 has not been used for more than four epochs: the next purge releases it, key 2 stays.
        #expect(cache.value(for: 2, epoch: 13, owners: { [] }, create: { 4 }) == 3)
        #expect(retained == nil)
        #expect(cache.value(for: 1, epoch: 13, owners: { [] }, create: { 5 }) == 5)
    }

    @Test
    func aFullCacheDropsStaleEntriesBeforeTheLiveWorkingSet() {
        var cache = TransientResourceCache<Int, Int>(maximumAge: 2, capacity: 2)
        _ = cache.value(for: 1, epoch: 0, owners: { [] }, create: { 1 })
        _ = cache.value(for: 2, epoch: 2, owners: { [] }, create: { 2 })
        // Key 1 is stale at epoch 3; inserting key 3 evicts it and keeps key 2.
        _ = cache.value(for: 3, epoch: 3, owners: { [] }, create: { 3 })
        #expect(cache.count == 2)
        #expect(cache.value(for: 2, epoch: 3, owners: { [] }, create: { 20 }) == 2)
    }

    @Test
    func failedCreationIsNotCached() {
        var cache = TransientResourceCache<Int, Int>()
        #expect(cache.value(for: 1, epoch: 0, owners: { [] }, create: { nil }) == nil)
        #expect(cache.value(for: 1, epoch: 0, owners: { [] }, create: { 7 }) == 7)
    }
}
