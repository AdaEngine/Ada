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

    struct TriangleMeshShape: Codable, Hashable, Sendable {
        let vertices: [Vector3]
        let indices: [UInt32]
    }

    public enum TriangleMeshError: Error, Sendable {
        case invalidVertices
        case invalidIndices
        case degenerateTriangle
    }

    enum Fixture: Codable, Hashable, Equatable, Sendable {
        case box(BoxShape)
        case sphere(SphereShape)
        case triangleMesh(TriangleMeshShape)
    }

    let fixture: Fixture

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fixture = try container.decode(Fixture.self, forKey: .fixture)
        if case let .triangleMesh(mesh) = fixture {
            _ = try Self.generateTriangleMesh(vertices: mesh.vertices, indices: mesh.indices)
        }
        self.fixture = fixture
    }

    private enum CodingKeys: CodingKey { case fixture }

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

    /// Creates a static, single-sided triangle collider in body-local units. Winding defines
    /// the solid side (counterclockwise as seen from above for terrain). Entity scale is ignored.
    public static func generateTriangleMesh(vertices: [Vector3], indices: [UInt32]) throws(TriangleMeshError) -> Shape3DResource {
        guard vertices.count >= 3, vertices.count <= Int(Int32.max),
            vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else { throw .invalidVertices }
        guard !indices.isEmpty, indices.count.isMultiple(of: 3), indices.count <= Int(Int32.max),
            indices.allSatisfy({ Int($0) < vertices.count })
        else { throw .invalidIndices }
        for index in stride(from: 0, to: indices.count, by: 3) {
            let first = vertices[Int(indices[index])]
            let cross = (vertices[Int(indices[index + 1])] - first).cross(vertices[Int(indices[index + 2])] - first)
            guard cross.length.isFinite, cross.length > 0.000001 else { throw .degenerateTriangle }
        }
        return Shape3DResource(fixture: .triangleMesh(TriangleMeshShape(vertices: vertices, indices: indices)))
    }

    /// Creates a sphere shape offset from the body origin.
    public func offsetBy(x: Float, y: Float, z: Float) -> Shape3DResource {
        switch self.fixture {
        case .box, .triangleMesh:
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
