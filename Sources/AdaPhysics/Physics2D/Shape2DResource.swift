//
//  Shape2DResource.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import Math

/// A representation of a shape.
public final class Shape2DResource: Codable, Sendable {
    struct CircleShape: Codable, Hashable, Equatable, Sendable {
        let radius: Float
        var offset: Vector2 = .zero
    }

    struct BoxShape: Codable, Hashable, Equatable, Sendable {
        let halfWidth: Float
        let halfHeight: Float
        var offset: Vector2 = .zero
    }

    struct PolygonShape: Codable, Hashable, Equatable, Sendable {
        let verticies: [Vector2]
        var offset: Vector2 = .zero
    }

    enum Fixture: Codable, Hashable, Equatable, Sendable {
        case circle(CircleShape)
        case box(BoxShape)
        case polygon(PolygonShape)
    }

    let fixture: Fixture

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    /// Creates a circle shape with the specified radius.
    public static func generateCircle(radius: Float = 1) -> Shape2DResource {
        return Shape2DResource(fixture: .circle(CircleShape(radius: radius / 2)))
    }

    /// Creates a box shape with the specified size. By default size is equal entity transformation scale value.
    public static func generateBox(width: Float = 1, height: Float = 1) -> Shape2DResource {
        return Shape2DResource(fixture: .box(BoxShape(halfWidth: width / 2, halfHeight: height / 2)))
    }

    /// Creates a box shape with the specified size and rotation.
    /// By default size is equal entity transformation scale value.
    public static func generateBox(width: Float = 1, height: Float = 1, center: Vector2, angle _: Float) -> Shape2DResource {
        return Shape2DResource(fixture: .box(BoxShape(halfWidth: width / 2, halfHeight: height / 2, offset: center)))
    }

    /// Create a custom polygon shape.
    public static func generatePolygon(vertices: [Vector2]) -> Shape2DResource {
        return Shape2DResource(fixture: .polygon(PolygonShape(verticies: vertices)))
    }

    /// Creates a new shape resource by applying a rotation.
    public func offsetBy(x: Float, y: Float) -> Shape2DResource {
        switch self.fixture {
        case var .box(shape):
            shape.offset = [x, y]

            return Shape2DResource(fixture: .box(shape))
        case var .circle(shape):
            shape.offset = [x, y]

            return Shape2DResource(fixture: .circle(shape))
        case var .polygon(shape):
            shape.offset = [x, y]

            return Shape2DResource(fixture: .polygon(shape))
        }
    }
}

// MARK: - Hashable & Equatable

extension Shape2DResource: Hashable, Equatable {
    public static func == (lhs: Shape2DResource, rhs: Shape2DResource) -> Bool {
        return lhs.fixture == rhs.fixture
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.fixture)
    }
}
