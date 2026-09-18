//
//  QueryResult.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/21/25.
//

/// Contains array of entities matched for the given EntityQuery request.
public struct QueryResult<B: QuertyTargetBuilder, F: Filter>: Sequence, Sendable {
    /// The element type of the query result.
    public typealias Element = B.Components

    /// The iterator type of the query result.
    public typealias Iterator = FilterQueryIterator<B, F>

    /// The state of the query result.
    let state: QueryState

    /// Initialize a new query result.
    /// - Parameter state: The state of the query result.
    internal init(state: QueryState) {
        self.state = state
    }

    /// Returns first element of collection.
    public var first: Element? {
        return self.first { _ in return true }
    }

    /// Calculate count of element in collection
    /// - Complexity: O(n)
    public var count: Int {
        return self.count { _ in return true }
    }

    /// A Boolean value indicating whether the collection is empty.
    public var isEmpty: Bool {
        return self.state.archetypeIndecies.isEmpty
    }

    public func makeIterator() -> Iterator {
        FilterQueryIterator<B, F>(state: state)
    }
}
