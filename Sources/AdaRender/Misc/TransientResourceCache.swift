/// A cache for GPU bindings that may reference resources which must not be retained long term,
/// such as render attachments that are replaced on resize.
///
/// Entries retain their owners only while they are used: an entry not used within ``maximumAge``
/// epochs is dropped, which releases a replaced resource shortly after its last use. Callers advance
/// the epoch once per command submission; a frame submits several, so the default age spans a few frames.
/// Purging runs when the owning cache is used again, so an unused pipeline keeps its entries until it is freed. The WebGPU main pass binds attachments (shadow atlases,
/// contact depth) beside material textures, so without this cache every draw created a bind group.
struct TransientResourceCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let owners: [AnyObject]
        var lastUsed: UInt64
    }

    let maximumAge: UInt64
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var lastPurge: UInt64 = 0

    init(maximumAge: UInt64 = 64, capacity: Int = 2_048) {
        self.maximumAge = maximumAge
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    /// Returns the cached value for `key`, creating it on a miss. `owners` is evaluated only on insertion.
    mutating func value(for key: Key, epoch: UInt64, owners: () -> [AnyObject], create: () -> Value?) -> Value? {
        if epoch &- lastPurge > maximumAge { purge(epoch: epoch) }
        if let entry = entries[key] {
            entries[key]?.lastUsed = epoch
            return entry.value
        }
        guard let value = create() else { return nil }
        if entries.count >= capacity {
            purge(epoch: epoch)
            // Still full: the live working set exceeds the capacity. Drop it rather than grow without bound.
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        }
        entries[key] = Entry(value: value, owners: owners(), lastUsed: epoch)
        return value
    }

    private mutating func purge(epoch: UInt64) {
        lastPurge = epoch
        entries = entries.filter { epoch &- $0.value.lastUsed <= maximumAge }
    }
}
