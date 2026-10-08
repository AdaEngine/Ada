//
//  Sequence+Concurrency.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.11.2025.
//

extension Sequence {
    @inlinable
    public func forEach(
        isolated _: (any Actor)? = #isolation,
        _ body: (Self.Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await body(element)
        }
    }
}
