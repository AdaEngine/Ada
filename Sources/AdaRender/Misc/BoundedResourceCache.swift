/// A bounded cache whose entries retain the owners used to form identity keys.
/// Holding those owners prevents ObjectIdentifier reuse while a cached GPU binding lives.
struct BoundedResourceCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let owners: [AnyObject]
    }
    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var nextEvictionIndex = 0
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { entries.count }

    mutating func value(for key: Key, owners: [AnyObject], create: () -> Value?) -> Value? {
        value(for: key, owners: { owners }, create: create)
    }

    /// Builds the owner list only when a new entry is inserted, keeping cache hits allocation-free.
    mutating func value(for key: Key, owners: () -> [AnyObject], create: () -> Value?) -> Value? {
        if let entry = entries[key] {
            return entry.value
        }
        guard let value = create() else {
            return nil
        }
        // Evict one oldest binding, preserving the rest of the working set.
        // Clearing the whole cache makes a single new resource rebuild unrelated
        // GPU bindings as well. The ring keeps eviction and cache hits O(1).
        if entries.count >= capacity {
            entries.removeValue(forKey: insertionOrder[nextEvictionIndex])
            insertionOrder[nextEvictionIndex] = key
            nextEvictionIndex = (nextEvictionIndex + 1) % capacity
        } else {
            insertionOrder.append(key)
        }
        entries[key] = Entry(value: value, owners: owners())
        return value
    }
}
