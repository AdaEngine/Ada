//
//  SparseSet.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 15.11.2025.
//

@frozen
public struct SparseSet<Key: Hashable, Value> {
    public typealias Index = Int
    public typealias Element = Value
    public typealias DenseValue = (key: Key, value: Value)

    @usableFromInline
    var dense: ContiguousArray<DenseValue>
    @usableFromInline
    var sparse: [Key: Index]

    public init() {
        self.dense = []
        self.sparse = [:]
    }
}

extension SparseSet {
    public init(_ dictionary: [Key: Value]) {
        var set = SparseSet<Key, Value>()
        for (key, value) in dictionary {
            set.insert(value, for: key)
        }
        self = set
    }
}

extension SparseSet {
    @inlinable
    public var values: ContiguousArray<DenseValue> {
        _read {
            yield self.dense
        }
    }

    @inlinable
    public func firstIndex(for key: Key) -> Index? {
        guard let index = sparse[key], index < count else {
            return nil
        }
        return index
    }

    @inlinable
    public func firstValue(for key: Key) -> Value? {
        guard let index = firstIndex(for: key) else {
            return nil
        }
        let value = dense[index]
        assert(value.key == key, "Stored value has different key")
        return value.value
    }

    @inlinable
    public func contains(_ key: Key) -> Bool {
        sparse[key].map { $0 < count } ?? false
    }

    @discardableResult
    @inlinable
    public mutating func insert(_ value: Value, for key: Key) -> DenseValue {
        let newPair = (key, value)
        if let index = firstIndex(for: key) {
            dense[index] = newPair
            return newPair
        }

        let index = dense.count
        dense.append(newPair)
        sparse[key] = index
        return newPair
    }

    @discardableResult
    @inlinable
    public mutating func remove(for key: Key) -> DenseValue? {
        guard let index = firstIndex(for: key) else {
            return nil
        }

        let removed = swapAndRemove(at: index)
        if !dense.isEmpty, index < dense.count {
            let swappedElement = dense[index]
            sparse[swappedElement.key] = index
        }
        sparse[key] = nil
        return removed
    }

    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self.dense.removeAll(keepingCapacity: keepingCapacity)
        self.sparse.removeAll(keepingCapacity: keepingCapacity)
    }

    @inlinable
    public subscript(_ key: Key) -> Value? {
        get {
            return firstValue(for: key)
        }
        set {
            if let newValue {
                insert(newValue, for: key)
            } else {
                remove(for: key)
            }
        }
    }

    @inlinable
    public subscript(_ key: Key, default value: Value) -> Value? {
        get {
            return firstValue(for: key) ?? value
        }
        set {
            if let newValue {
                insert(newValue, for: key)
            } else {
                remove(for: key)
            }
        }
    }
}

extension SparseSet {
    @inlinable
    mutating func swapAndRemove(at index: Index) -> DenseValue? {
        dense.swapAt(index, dense.count - 1)
        return dense.removeLast()
    }
}

extension SparseSet: Sequence {
    @inlinable
    public func makeIterator() -> SparseSetIterator {
        SparseSetIterator(collection: dense)
    }

    @inlinable
    public var isEmpty: Bool {
        dense.isEmpty
    }

    @inlinable
    public var count: Int {
        dense.count
    }

    public struct SparseSetIterator: IteratorProtocol {
        @usableFromInline
        var iterator: IndexingIterator<ContiguousArray<DenseValue>>

        @usableFromInline
        init(collection: ContiguousArray<DenseValue>) {
            iterator = collection.makeIterator()
        }

        @inlinable
        public mutating func next() -> Element? {
            iterator.next()?.value
        }
    }
}

extension SparseSet: Sendable where Value: Sendable, Key: Sendable {}

extension SparseSet: Codable where Value: Codable, Key: Codable {
    enum CodingKeys: CodingKey {
        case dense, sparse
    }

    private struct CodableDenseValue: Codable {
        let key: Key
        let value: Value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let denseValues = try container.decode([CodableDenseValue].self, forKey: .dense)
        self.sparse = try container.decode([Key: Index].self, forKey: .sparse)
        self.dense = ContiguousArray(denseValues.map { ($0.key, $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sparse, forKey: .sparse)
        try container.encode(
            dense.map { CodableDenseValue(key: $0.key, value: $0.value) },
            forKey: .dense
        )
    }
}

extension SparseSet: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, Value)...) {
        var set = SparseSet<Key, Value>()
        for (key, value) in elements {
            set.insert(value, for: key)
        }
        self = set
    }
}
