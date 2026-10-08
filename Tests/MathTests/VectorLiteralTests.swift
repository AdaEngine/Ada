//
//  VectorLiteralTests.swift
//  AdaEngine
//

import Testing

@testable import Math

@Suite("Vector Literal Tests")
struct VectorLiteralTests {
    @Test func `vector2 initializes every component from float literal`() {
        let value: Vector2 = 1.5

        #expect(value == Vector2(1.5, 1.5))
    }

    @Test func `vector3 initializes every component from float literal`() {
        let value: Vector3 = 2.25

        #expect(value == Vector3(2.25, 2.25, 2.25))
    }

    @Test func `vector4 initializes every component from float literal`() {
        let value: Vector4 = 3.75

        #expect(value == Vector4(3.75, 3.75, 3.75, 3.75))
    }
}
