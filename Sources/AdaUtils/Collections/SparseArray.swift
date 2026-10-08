//
//  SparseArray.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/26/23.
//

/// Fast collection O(1) for insertion and deletion, but slow for resizing and iterating.
@frozen
public struct SparseArray<Element> {
    public typealias Index = Int

    public var values: [Element?]

    @inlinable
    public init(capacity: Int) {
        self.values = [Element?].init(repeating: nil, count: capacity)
    }

    @inlinable
    public init<T: Sequence>(_ sequence: T) where T.Element == Element {
        self.values = [Element?].init(repeating: nil, count: sequence.underestimatedCount)

        for (index, element) in sequence.enumerated() {
            self.values[index] = element
        }
    }
}

extension SparseArray {
    @inlinable
    public subscript(_ index: Index) -> Element? {
        get {
            precondition(index < self.underestimatedCount, "Index out of range")
            return self.values[index]
        }
        mutating set {
            self.insert(newValue, at: index)
        }
    }

    /// Removes all keys and their associated values from the sparse set.
    ///
    /// - Parameter keepingCapacity: If `true` then the underlying storage's
    ///   capacity is preserved. The default is `false`.
    ///
    /// - Complexity: O(`count`)
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            for index in 0..<self.values.count {
                self.values[index] = nil
            }
        } else {
            self.values.removeAll()
        }
    }

    /// - Complexity: O(1)
    @inlinable
    @discardableResult
    public mutating func remove(at index: Index) -> Element? {
        let element = self.values[index]
        self.values[index] = nil
        return element
    }

    @inlinable
    @discardableResult
    public mutating func removeLast() -> Element? {
        guard let index = self.values.lastIndex(where: { $0 != nil }) else {
            return nil
        }
        return remove(at: index)
    }

    @inlinable
    public mutating func insert(_ element: Element?, at index: Index) {
        self.values[index] = element
    }

    @inlinable
    public mutating func append(_ element: Element) {
        if count >= values.count {
            values.append(
                contentsOf: [Element?].init(repeating: nil, count: 16)
            )
        }
        self.insert(element, at: self.count)
    }
}

extension SparseArray: ExpressibleByArrayLiteral {
    @inlinable
    public init(arrayLiteral elements: Element...) {
        self = SparseArray(elements)
    }
}

extension SparseArray: Sequence {
    @inlinable
    public func index(after i: Int) -> Int {
        self.values.index(after: i)
    }

    @inlinable
    public var startIndex: Int {
        self.values.startIndex
    }

    @inlinable
    public var endIndex: Int {
        self.values.endIndex
    }

    /// - Complexity: O(1)
    @inlinable
    public var underestimatedCount: Int {
        return self.values.underestimatedCount
    }

    /// - Complexity: O(n)
    /// - Returns: Count of not null values.
    @inlinable
    public var count: Int {
        return self.values.count(where: { $0 != nil })
    }

    /// - Complexity: O(n)
    @inlinable
    public var isEmpty: Bool {
        // swiftlint:disable:next empty_count
        return self.count == 0
    }

    public func makeIterator() -> Iterator {
        Iterator(values: self.values)
    }

    public struct Iterator: IteratorProtocol {
        private var pointer: Int = -1
        let values: [Element?]

        init(values: [Element?]) {
            self.values = values
        }

        public mutating func next() -> Element? {
            while true {
                self.pointer += 1

                if self.pointer >= self.values.count {
                    return nil
                }

                guard let item = self.values[self.pointer] else {
                    continue
                }

                return item
            }
        }
    }
}

extension SparseArray: Equatable where Element: Equatable {
    public static func == (lhs: SparseArray<Element>, rhs: SparseArray<Element>) -> Bool {
        return lhs.values == rhs.values
    }
}

extension SparseArray: Sendable where Element: Sendable {}

extension SparseArray: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.count)
        hasher.combine(self.values)
    }
}
