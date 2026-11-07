/// Hard negative-inside field combination; ordered application supports non-destructive authoring.
public enum ScalarBooleanOperation: String, Codable, Equatable, Sendable {
    case union
    case subtract

    public func apply(base: Float, operand: Float) throws -> Float {
        guard base.isFinite, operand.isFinite else { throw ScalarSolidError.invalidDensity }
        switch self {
        case .union: return min(base, operand)
        case .subtract: return max(base, -operand)
        }
    }
}
