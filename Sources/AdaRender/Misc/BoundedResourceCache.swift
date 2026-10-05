/// A bounded cache whose entries retain the owners used to form identity keys.
/// Holding those owners prevents ObjectIdentifier reuse while a cached GPU binding lives.
struct BoundedResourceCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let owners: [AnyObject]
    }
    private var entries: [Key: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func value(for key: Key, owners: [AnyObject], create: () -> Value?) -> Value? {
        if let entry = entries[key] {
            return entry.value
        }
        guard let value = create() else {
            return nil
        }
        // Pipeline-local limits keep destroyed scene resources from being retained indefinitely.
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(value: value, owners: owners)
        return value
    }
}
