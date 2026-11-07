import Foundation

/// Failures from bounded scalar-field sampling and smooth surface extraction.
public enum ScalarFieldSurfaceError: LocalizedError, Equatable, Sendable {
    case invalidGrid
    case outputBudgetExceeded
    case topologyBudgetExceeded
    case unsupportedTopology

    public var errorDescription: String? {
        switch self {
        case .invalidGrid: "Scalar grids require 1...32 cells per axis, finite samples and distinguishable finite coordinates"
        case .outputBudgetExceeded: "Scalar surface extraction exceeds its triangle output budget"
        case .topologyBudgetExceeded: "Scalar surface contact processing exceeds its bounded work budget"
        case .unsupportedTopology: "Sampled surface contacts cannot be oriented at this precision; adjust the grid precision or operand placement"
        }
    }
}

/// Immutable negative-inside scalar samples on a uniform grid, with at most 32 cells per axis.
/// Samples are stored X fastest, then Y, then Z; each axis has one more sample than cells.
public struct ScalarFieldGrid: Sendable {
    /// Shared lattice origin. Cell coordinates include cellOffset before spacing is applied.
    public let origin: Vector3
    public let spacing: Float
    public let cellCount: SIMD3<Int32>
    public let values: [Float]
    /// Integer cell address relative to the shared lattice origin, independent of brick placement.
    public let cellOffset: SIMD3<Int32>

    /// Validates dimensions, sample count/data and coordinate precision before retaining the grid.
    public init(origin: Vector3, spacing: Float, cellCount: SIMD3<Int32>, values: [Float], cellOffset: SIMD3<Int32> = .zero) throws {
        guard (1...32).contains(cellCount.x), (1...32).contains(cellCount.y), (1...32).contains(cellCount.z),
            spacing.isFinite, spacing > 0, origin.x.isFinite, origin.y.isFinite, origin.z.isFinite
        else { throw ScalarFieldSurfaceError.invalidGrid }
        let count = (Int(cellCount.x) + 1) * (Int(cellCount.y) + 1) * (Int(cellCount.z) + 1)
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw ScalarFieldSurfaceError.invalidGrid }
        let components = SIMD3<Float>(origin.x, origin.y, origin.z)
        for axis in 0..<3 {
            var previous = Self.coordinate(components[axis], spacing: spacing, index: Int64(cellOffset[axis]))
            guard previous.isFinite else { throw ScalarFieldSurfaceError.invalidGrid }
            for index in 1...Int(cellCount[axis]) {
                let position = Self.coordinate(components[axis], spacing: spacing, index: Int64(cellOffset[axis]) + Int64(index))
                guard position.isFinite, position > previous else { throw ScalarFieldSurfaceError.invalidGrid }
                previous = position
            }
        }
        self.origin = origin; self.spacing = spacing; self.cellCount = cellCount; self.values = values
        self.cellOffset = cellOffset
    }

    func position(x: Int, y: Int, z: Int) -> Vector3 {
        Vector3(
            Self.coordinate(origin.x, spacing: spacing, index: Int64(cellOffset.x) + Int64(x)),
            Self.coordinate(origin.y, spacing: spacing, index: Int64(cellOffset.y) + Int64(y)),
            Self.coordinate(origin.z, spacing: spacing, index: Int64(cellOffset.z) + Int64(z))
        )
    }

    private static func coordinate(_ origin: Float, spacing: Float, index: Int64) -> Float { origin + Float(index) * spacing }
}
