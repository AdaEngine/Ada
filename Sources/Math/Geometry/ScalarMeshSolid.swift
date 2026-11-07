import Foundation

public enum ScalarMeshSolidError: LocalizedError, Equatable, Sendable {
    case invalidMesh
    case openOrNonManifold
    case inconsistentWinding
    case selfIntersection
    case workBudgetExceeded
    case invalidPoint
    case ambiguousSample

    public var errorDescription: String? {
        switch self {
        case .invalidMesh: "A solid requires finite, nondegenerate indexed triangles within its size limit"
        case .openOrNonManifold: "The mesh must be closed, with exactly two faces at each welded edge"
        case .inconsistentWinding: "Adjacent solid faces must have consistent winding"
        case .selfIntersection: "Solid faces intersect or overlap outside their shared topology"
        case .workBudgetExceeded: "Solid validation or sampling exceeded its work budget"
        case .invalidPoint: "Solid sample coordinates must be finite"
        case .ambiguousSample: "Solid classification is ambiguous at this coordinate precision"
        }
    }
}

/// An immutable closed triangle operand for sampled solid editing, including concave meshes.
public struct ScalarMeshSolid: Sendable {
    public let bounds: AABB
    private let hierarchy: ScalarMeshHierarchy
    private let origin: ScalarMeshPoint
    private let scale: Double

    /// Exact position duplicates are welded, including imported attribute seams.
    /// At most 65,536 triangles and 196,608 source vertices are retained for validation.
    public init(
        positions: [Vector3],
        indices: [UInt32],
        transform: Transform3D = .identity,
        maximumTriangles: Int = 65_536,
        maximumValidationWork: Int = 8_388_608
    ) throws {
        guard maximumTriangles > 0, maximumTriangles <= 65_536, positions.count <= 196_608,
            indices.count >= 12, indices.count.isMultiple(of: 3), indices.count / 3 <= maximumTriangles
        else { throw ScalarMeshSolidError.invalidMesh }
        var work = try ScalarMeshWork(maximumValidationWork)
        try work.spend(positions.count)
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ScalarMeshSolidError.invalidMesh }
        _ = try ScalarAffineFrame(transform)
        let welded = try ScalarMeshValidation.weld(positions, indices: indices, transform: transform, work: &work)
        var low = ScalarMeshPoint(repeating: .infinity), high = ScalarMeshPoint(repeating: -.infinity)
        for point in welded.points {
            try work.spend()
            let value = ScalarMeshPoint(Double(point.x), Double(point.y), Double(point.z))
            for axis in 0..<3 { low[axis] = min(low[axis], value[axis]); high[axis] = max(high[axis], value[axis]) }
        }
        let extent = high - low, scale = max(extent.x, max(extent.y, extent.z)), origin = low + extent * 0.5
        guard scale.isFinite, scale > 0 else { throw ScalarMeshSolidError.invalidMesh }
        let points = welded.points.map { (ScalarMeshPoint(Double($0.x), Double($0.y), Double($0.z)) - origin) / scale }
        var triangles: [ScalarMeshTriangle] = []
        triangles.reserveCapacity(indices.count / 3)
        for start in stride(from: 0, to: welded.indices.count, by: 3) {
            try work.spend()
            let triangle = ScalarMeshTriangle(ids: SIMD3(welded.indices[start], welded.indices[start + 1], welded.indices[start + 2]), points: points)
            let area = scalarMeshDot(triangle.normal, triangle.normal)
            guard area.isFinite, area > 0 else { throw ScalarMeshSolidError.invalidMesh }
            triangles.append(triangle)
        }
        try ScalarMeshValidation.topology(welded.indices, vertexCount: points.count, work: &work)
        let hierarchy = try ScalarMeshHierarchy(triangles: triangles, work: &work)
        try hierarchy.validateIntersections(work: &work)
        var half = ScalarMeshPoint(repeating: 0)
        let center = Vector3(Float(origin.x), Float(origin.y), Float(origin.z))
        for axis in 0..<3 { half[axis] = max(abs(low[axis] - Double(center[axis])), abs(high[axis] - Double(center[axis]))) }
        let extents = Vector3(Float(half.x).nextUp, Float(half.y).nextUp, Float(half.z).nextUp)
        guard extents.x.isFinite, extents.y.isFinite, extents.z.isFinite else { throw ScalarMeshSolidError.invalidMesh }
        let bounds = AABB(center: center, halfExtents: extents)
        let minimum = bounds.min, maximum = bounds.max
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite, maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite else {
            throw ScalarMeshSolidError.invalidMesh
        }
        self.bounds = bounds
        self.hierarchy = hierarchy; self.origin = origin; self.scale = scale
    }

    /// Negative inside, positive outside, zero at the surface; work exhaustion throws.
    public func value(at point: Vector3, maximumWork: Int = 1_048_576) throws -> Float {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw ScalarMeshSolidError.invalidPoint }
        var work = try ScalarMeshWork(maximumWork)
        let normalized = (ScalarMeshPoint(Double(point.x), Double(point.y), Double(point.z)) - origin) / scale
        let squared = try hierarchy.squaredDistance(normalized, work: &work)
        if squared == 0 {
            return 0
        }
        let sign: Double = try hierarchy.isInside(normalized, work: &work) ? -1 : 1
        let result = Float(squared.squareRoot() * scale * sign)
        guard result.isFinite else { throw ScalarSolidError.unrepresentableResult }
        return result
    }
}
