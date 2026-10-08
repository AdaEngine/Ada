//
//  Transform2DRegressionTests.swift
//  AdaEngine
//
//  Created by Codex on 4/20/26.
//

import Numerics
import Testing

@testable import Math

@Suite("Transform 2D Regression Tests")
struct Transform2DRegressionTests {
    @Test func `scale getter returns basis lengths for rotated transforms`() {
        let transform = Transform2D(scale: [2, 3]).rotated(by: .degrees(30))

        #expect(transform.scale.x.isApproximatelyEqual(to: 2, absoluteTolerance: 0.00001))
        #expect(transform.scale.y.isApproximatelyEqual(to: 3, absoluteTolerance: 0.00001))
    }

    @Test func `transpose swaps rows and columns`() {
        let transform = Transform2D(
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]
        )

        let expected = Transform2D(
            [1, 4, 7],
            [2, 5, 8],
            [3, 6, 9]
        )

        #expect(transform.transpose == expected)
    }
}
