import Foundation

public enum TriangleSurfaceQueryError: LocalizedError, Equatable, Sendable {
    case invalidMesh
    case invalidQuery
    case memoryBudgetExceeded
    case workBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidMesh: "Surface queries require finite, nondegenerate indexed triangles within their size limit"
        case .invalidQuery: "Surface queries require finite points, a nonzero ray direction and a finite nonnegative distance"
        case .memoryBudgetExceeded: "Surface query acceleration exceeds its geometry allocation allowance"
        case .workBudgetExceeded: "Surface query construction or traversal exceeds its work allowance"
        }
    }
}

/// A bounded work allowance shared by queries across independently indexed surface tiles.
public struct TriangleSurfaceQueryBudget: Sendable {
    public private(set) var remaining: Int
    public init(maximumWork: Int) throws {
        guard maximumWork >= 0 else { throw TriangleSurfaceQueryError.workBudgetExceeded }
        try Task.checkCancellation()
        remaining = maximumWork
    }
    /// Charges caller bounds and index node/triangle visits without resetting the shared allowance.
    public mutating func charge(_ count: Int = 1) throws {
        guard count >= 0, count <= remaining else { throw TriangleSurfaceQueryError.workBudgetExceeded }
        if remaining.isMultiple(of: 256) || count >= 256 { try Task.checkCancellation() }
        remaining -= count
    }
}

public struct TriangleSurfaceHit: Sendable {
    public let position: Vector3
    /// Geometric winding normal, including for a ray hitting the triangle's back face.
    public let normal: Vector3
    public let distance: Float
    /// Unrounded distance for ordering distinguishable hits across independent indices.
    public let preciseDistance: Double
    /// Index in the original triangle list, retained through BVH sorting.
    public let triangleIndex: Int
}

/// Immutable acceleration for finite indexed triangle surfaces, including open terrain meshes.
public struct TriangleSurfaceIndex: Sendable {
    /// Conservative retained BVH, recursive sort and triangle construction staging charge.
    public static let bytesPerTriangle = MemoryLayout<ScalarMeshTriangle>.stride * 4 + MemoryLayout<ScalarMeshNode>.stride * 2 + 64
    public let generation = UUID()
    public let chargedBytes: Int
    public let constructionWork: Int
    public let triangleCount: Int
    private let hierarchy: ScalarMeshHierarchy?

    public init(
        positions: [Vector3],
        indices: [UInt32],
        maximumTriangles: Int = 262_144,
        maximumBytes: Int = 64 * 1_024 * 1_024,
        maximumWork: Int = 16_777_216
    ) throws {
        try Task.checkCancellation()
        guard (0...262_144).contains(maximumTriangles), positions.count <= 1_048_576, indices.count.isMultiple(of: 3), maximumBytes >= 0 else {
            throw TriangleSurfaceQueryError.invalidMesh
        }
        let count = indices.count / 3
        guard count <= maximumTriangles, count <= maximumBytes / Self.bytesPerTriangle else { throw TriangleSurfaceQueryError.memoryBudgetExceeded }
        do {
            var work = try ScalarMeshWork(maximumWork)
            var triangles: [ScalarMeshTriangle] = []
            triangles.reserveCapacity(count)
            for offset in stride(from: 0, to: indices.count, by: 3) {
                try work.spend()
                let ids = SIMD3(indices[offset], indices[offset + 1], indices[offset + 2])
                guard let a = Int(exactly: ids.x), let b = Int(exactly: ids.y), let c = Int(exactly: ids.z),
                    positions.indices.contains(a), positions.indices.contains(b), positions.indices.contains(c),
                    TriangleSurfaceGeometry.finite(positions[a]), TriangleSurfaceGeometry.finite(positions[b]), TriangleSurfaceGeometry.finite(positions[c]) else {
                    throw TriangleSurfaceQueryError.invalidMesh
                }
                // Only referenced rows become Double geometry; large unused accessors are not copied.
                let triangle = ScalarMeshTriangle(
                    ids: ids,
                    a: TriangleSurfaceGeometry.point(positions[a]),
                    b: TriangleSurfaceGeometry.point(positions[b]),
                    c: TriangleSurfaceGeometry.point(positions[c]),
                    sourceIndex: offset / 3
                )
                let area = scalarMeshDot(triangle.normal, triangle.normal)
                guard area.isFinite, area > 0 else { throw TriangleSurfaceQueryError.invalidMesh }
                triangles.append(triangle)
            }
            hierarchy = triangles.isEmpty ? nil : try ScalarMeshHierarchy(triangles: triangles, work: &work)
            triangleCount = count; chargedBytes = count * Self.bytesPerTriangle
            constructionWork = maximumWork - work.available
        } catch ScalarMeshSolidError.workBudgetExceeded { throw TriangleSurfaceQueryError.workBudgetExceeded }
    }

    package var bounds: AABB? {
        guard let root = hierarchy?.nodes.first else { return nil }
        return .init(min: [Float(root.low.x), Float(root.low.y), Float(root.low.z)],
                     max: [Float(root.high.x), Float(root.high.y), Float(root.high.z)])
    }

    /// Visits triangle bounds in a local region without copying the index.
    package func visitTriangles(
        overlapping region: AABB, budget: inout TriangleSurfaceQueryBudget, _ visit: (Int) throws -> Void
    ) throws {
        guard let hierarchy else { return }
        let low = TriangleSurfaceGeometry.point(region.min), high = TriangleSurfaceGeometry.point(region.max)
        var cursor = 0
        while cursor < hierarchy.nodes.count {
            try budget.charge()
            let node = hierarchy.nodes[cursor]
            guard node.overlaps(low, high) else { cursor = node.end; continue }
            for index in node.start..<(node.start + node.count) {
                try budget.charge()
                let triangle = hierarchy.triangles[index]
                if triangle.low.x <= high.x, triangle.high.x >= low.x, triangle.low.y <= high.y, triangle.high.y >= low.y,
                    triangle.low.z <= high.z, triangle.high.z >= low.z {
                    try visit(triangle.sourceIndex)
                }
            }
            cursor += 1
        }
    }

    /// Distance uses the normalized ray direction, regardless of the input direction's length.
    public func raycast(_ ray: Ray, maximumDistance: Float = .greatestFiniteMagnitude, maximumWork: Int = 1_048_576) throws -> TriangleSurfaceHit? {
        var budget = try TriangleSurfaceQueryBudget(maximumWork: maximumWork)
        return try raycast(ray, maximumDistance: maximumDistance, budget: &budget)
    }

    public func raycast(_ ray: Ray, maximumDistance: Float = .greatestFiniteMagnitude, budget: inout TriangleSurfaceQueryBudget) throws -> TriangleSurfaceHit? {
        try raycast(ray, maximumDistance: maximumDistance, budget: &budget, preferEqualHit: (<))
    }

    /// Resolves coincident hits using the caller's stable geometry order.
    package func raycast(
        _ ray: Ray, maximumDistance: Float, budget: inout TriangleSurfaceQueryBudget,
        preferEqualHit: (Int, Int) -> Bool
    ) throws -> TriangleSurfaceHit? {
        try Task.checkCancellation()
        guard TriangleSurfaceGeometry.finite(ray.origin), TriangleSurfaceGeometry.finite(ray.direction), maximumDistance.isFinite, maximumDistance >= 0 else {
            throw TriangleSurfaceQueryError.invalidQuery
        }
        let rawDirection = TriangleSurfaceGeometry.point(ray.direction), length = scalarMeshDot(rawDirection, rawDirection).squareRoot()
        guard length > 0 else { throw TriangleSurfaceQueryError.invalidQuery }
        guard let hierarchy else {
            return nil
        }
        let direction = rawDirection / length, origin = TriangleSurfaceGeometry.point(ray.origin)
        var best = Double(maximumDistance), result: TriangleSurfaceHit?, cursor = 0
        while cursor < hierarchy.nodes.count {
            try budget.charge()
            let node = hierarchy.nodes[cursor]
            if !TriangleSurfaceGeometry.intersects(node, origin: origin, direction: direction, maximumDistance: best) { cursor = node.end; continue }
            for index in node.start..<(node.start + node.count) {
                try budget.charge()
                let triangle = hierarchy.triangles[index]
                if let (distance, position) = TriangleSurfaceGeometry.rayHit(triangle, origin: origin, direction: direction, maximumDistance: best),
                    result == nil || distance < best || (distance == best && preferEqualHit(triangle.sourceIndex, result?.triangleIndex ?? .max)) {
                    best = distance; result = TriangleSurfaceGeometry.hit(position, distance: distance, triangle: triangle)
                }
            }
            cursor += 1
        }
        return result
    }

    public func closest(to point: Vector3, maximumDistance: Float = .greatestFiniteMagnitude, maximumWork: Int = 1_048_576) throws -> TriangleSurfaceHit? {
        var budget = try TriangleSurfaceQueryBudget(maximumWork: maximumWork)
        return try closest(to: point, maximumDistance: maximumDistance, budget: &budget)
    }

    public func closest(to point: Vector3, maximumDistance: Float = .greatestFiniteMagnitude, budget: inout TriangleSurfaceQueryBudget) throws -> TriangleSurfaceHit? {
        try closest(to: point, maximumDistance: maximumDistance, budget: &budget) { _, _ in true }
    }

    /// Finds the nearest eligible triangle using its original face index and winding normal.
    public func closest(
        to point: Vector3,
        maximumDistance: Float,
        budget: inout TriangleSurfaceQueryBudget,
        where isEligible: (Int, Vector3) -> Bool
    ) throws -> TriangleSurfaceHit? {
        try Task.checkCancellation()
        guard TriangleSurfaceGeometry.finite(point), maximumDistance.isFinite, maximumDistance >= 0 else { throw TriangleSurfaceQueryError.invalidQuery }
        guard let hierarchy else {
            return nil
        }
        let point = TriangleSurfaceGeometry.point(point)
        var best = Double(maximumDistance) * Double(maximumDistance), result: TriangleSurfaceHit?, cursor = 0
        while cursor < hierarchy.nodes.count {
            try budget.charge()
            let node = hierarchy.nodes[cursor]
            if node.squaredDistance(point) > best { cursor = node.end; continue }
            for index in node.start..<(node.start + node.count) {
                try budget.charge()
                let triangle = hierarchy.triangles[index], position = TriangleSurfaceGeometry.closestPoint(point, triangle: triangle), difference = position - point
                let distance = scalarMeshDot(difference, difference)
                if distance <= best, result == nil || distance < best || (distance == best && triangle.sourceIndex < (result?.triangleIndex ?? .max)) {
                    let hit = TriangleSurfaceGeometry.hit(position, distance: distance.squareRoot(), triangle: triangle)
                    guard isEligible(hit.triangleIndex, hit.normal) else { continue }
                    best = distance; result = hit
                }
            }
            cursor += 1
        }
        return result
    }
}
