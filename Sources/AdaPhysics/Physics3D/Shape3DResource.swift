//
//  Shape3DResource.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import Math

/// A 3D physics shape description.
public final class Shape3DResource: Codable, Sendable {
    struct BoxShape: Codable, Hashable, Equatable, Sendable {
        let halfExtents: Vector3
    }

    struct SphereShape: Codable, Hashable, Equatable, Sendable {
        let radius: Float
        var center: Vector3 = .zero
    }

    enum Fixture: Codable, Hashable, Equatable, Sendable {
        case box(BoxShape)
        case sphere(SphereShape)
    }

    let fixture: Fixture

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    /// Creates a box shape with the specified size.
    public static func generateBox(width: Float = 1, height: Float = 1, depth: Float = 1) -> Shape3DResource {
        return Shape3DResource(
            fixture: .box(
                BoxShape(
                    halfExtents: [
                        width / 2,
                        height / 2,
                        depth / 2,
                    ]
                )
            )
        )
    }

    /// Creates a sphere shape with the specified radius.
    public static func generateSphere(radius: Float = 1) -> Shape3DResource {
        return Shape3DResource(fixture: .sphere(SphereShape(radius: radius)))
    }

    /// Creates a sphere shape offset from the body origin.
    public func offsetBy(x: Float, y: Float, z: Float) -> Shape3DResource {
        switch self.fixture {
        case .box:
            return self
        case var .sphere(shape):
            shape.center = [x, y, z]
            return Shape3DResource(fixture: .sphere(shape))
        }
    }
}

// MARK: - Hashable & Equatable

extension Shape3DResource: Hashable, Equatable {
    public static func == (lhs: Shape3DResource, rhs: Shape3DResource) -> Bool {
        return lhs.fixture == rhs.fixture
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.fixture)
    }
}
