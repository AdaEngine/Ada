//
//  Vector2Tests.swift
//  AdaEngine
//
//  Created by Codex on 4/20/26.
//

import Numerics
import Testing

@testable import Math

@Suite("Vector 2 Tests")
struct Vector2Tests {
    @Test func `normalized uses vector length`() {
        let normalized = Vector2(3, 4).normalized

        #expect(normalized.x.isApproximatelyEqual(to: 0.6, absoluteTolerance: 0.00001))
        #expect(normalized.y.isApproximatelyEqual(to: 0.8, absoluteTolerance: 0.00001))
    }

    @Test func `normalizing zero vector returns zero`() {
        #expect(Vector2.zero.normalized == .zero)
    }
}
