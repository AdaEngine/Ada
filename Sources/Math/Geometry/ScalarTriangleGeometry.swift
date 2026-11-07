enum ScalarTriangleGeometry {
    /// Anchor at the shortest edge. Subtracting two long, almost equal edges can
    /// otherwise discard a representable thin triangle even in Double arithmetic.
    /// Cyclic rotation preserves the caller's winding.
    static func normal(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> SIMD3<Double> {
        let first = point(a), second = point(b), third = point(c)
        let ab = second - first, bc = third - second, ca = first - third
        let firstLength = squared(ab), secondLength = squared(bc), thirdLength = squared(ca)
        if firstLength <= secondLength && firstLength <= thirdLength {
            return cross(ab, third - first)
        }
        if secondLength <= thirdLength {
            return cross(bc, first - second)
        }
        return cross(ca, second - third)
    }

    static func squared(_ value: SIMD3<Double>) -> Double { value.x * value.x + value.y * value.y + value.z * value.z }
    private static func point(_ value: Vector3) -> SIMD3<Double> { SIMD3(Double(value.x), Double(value.y), Double(value.z)) }
    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
