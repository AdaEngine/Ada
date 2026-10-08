//
//  ConcurrentSequence.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/30/24.
//

public struct ConcurrentSequence<S: Sequence> {
    public typealias Element = S.Element

    private let base: S

    init(base: S) {
        self.base = base
    }
}

extension Sequence {
    /// Create wrapper for sequence to use Swift Modern Concurrency.
    public var concurrent: ConcurrentSequence<Self> {
        ConcurrentSequence(base: self)
    }
}

extension ConcurrentSequence {
    /// Iterate over all elements in sequence and create task for each.
    @concurrent
    public func forEach(
        _ operation: @escaping @Sendable (Element) async -> Void
    ) async where Element: Sendable {
        // A task group automatically waits for all of its
        // sub-tasks to complete, while also performing those
        // tasks in parallel:
        await withTaskGroup(of: Void.self) { group in
            for element in self.base {
                group.addTask { @Sendable [element] in
                    await operation(element)
                }
            }
        }
    }
}
