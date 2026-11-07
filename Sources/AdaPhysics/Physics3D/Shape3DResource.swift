//
//  Shape3DResource.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import Foundation
import Math
import Synchronization

/// A 3D physics shape description.
public final class Shape3DResource: Codable, Sendable {
    struct BoxShape: Codable, Hashable, Equatable, Sendable {
        let halfExtents: Vector3
        /// Offset of the box center from the body origin.
        var center: Vector3 = .zero

        init(halfExtents: Vector3, center: Vector3 = .zero) {
            self.halfExtents = halfExtents
            self.center = center
        }

        private enum CodingKeys: CodingKey { case halfExtents, center }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.halfExtents = try container.decode(Vector3.self, forKey: .halfExtents)
            // Shapes saved before boxes could be offset have no center.
            self.center = try container.decodeIfPresent(Vector3.self, forKey: .center) ?? .zero
        }
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
    private let preparedMesh = Mutex<NativeTriangleMesh3D?>(nil)
    /// Immutable body-local bounds, cached without re-reading triangle vertices during residency planning.
    public let localBounds: AABB?

    init(fixture: Fixture) {
        self.fixture = fixture
        self.localBounds = Self.calculateBounds(fixture)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fixture = try container.decode(Fixture.self, forKey: .fixture)
        let bounds: AABB?
        if case let .triangleMesh(mesh) = fixture {
            bounds = try Self.generateTriangleMesh(vertices: mesh.vertices, indices: mesh.indices).localBounds
        } else {
            bounds = Self.calculateBounds(fixture)
        }
        self.fixture = fixture
        self.localBounds = bounds
    }

    private enum CodingKeys: CodingKey { case fixture }

    /// Creates a box shape with the specified size, optionally offset from the body origin.
    public static func generateBox(width: Float = 1, height: Float = 1, depth: Float = 1, center: Vector3 = .zero) -> Shape3DResource {
        return Shape3DResource(
            fixture: .box(
                BoxShape(
                    halfExtents: [
                        width / 2,
                        height / 2,
                        depth / 2,
                    ],
                    center: center
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
            // Match the native normalizer's representable range rather than imposing
            // a world-unit area cutoff: isosurface intersections legitimately form thin faces.
            let squaredArea = cross.dot(cross)
            guard squaredArea.isFinite, squaredArea > 1_000 * Float.leastNormalMagnitude else { throw .degenerateTriangle }
        }
        return Shape3DResource(fixture: .triangleMesh(TriangleMeshShape(vertices: vertices, indices: indices)))
    }

    /// Prepares immutable native triangle data without adding a body to the physics world.
    /// Subsequent bodies reuse this resource; preparation failures leave no active collision.
    @_spi(Internal)
    public func prepareStaticCollision(metrics: PhysicsCollisionPreparationMetrics? = nil) throws(StaticCollisionPreparationError) {
        guard case .triangleMesh = fixture else {
            return
        }
        guard unsafe nativeTriangleMesh(metrics: metrics) != nil else { throw .nativeMeshCreationFailed }
    }

    @unsafe
    func nativeTriangleMesh(metrics: PhysicsCollisionPreparationMetrics?) -> NativeTriangleMesh3D? {
        guard case let .triangleMesh(mesh) = fixture else {
            return nil
        }
        return preparedMesh.withLock { value in
            if let value {
                return value
            }
            let native = unsafe NativeTriangleMesh3D(mesh, metrics: metrics)
            value = native
            return native
        }
    }

    /// Creates a sphere or box shape offset from the body origin. Triangle meshes are returned unchanged.
    public func offsetBy(x: Float, y: Float, z: Float) -> Shape3DResource {
        switch self.fixture {
        case .triangleMesh:
            return self
        case var .box(shape):
            shape.center = [x, y, z]
            return Shape3DResource(fixture: .box(shape))
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

@_spi(Internal)
public enum StaticCollisionPreparationError: LocalizedError {
    case nativeMeshCreationFailed

    public var errorDescription: String? { "Native triangle collision preparation failed" }
}
