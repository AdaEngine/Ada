import Foundation

typealias ScalarMeshPoint = SIMD3<Double>

func scalarMeshDot(_ a: ScalarMeshPoint, _ b: ScalarMeshPoint) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
func scalarMeshCross(_ a: ScalarMeshPoint, _ b: ScalarMeshPoint) -> ScalarMeshPoint {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

struct ScalarMeshTriangle: Sendable {
    let ids: SIMD3<UInt32>
    let sourceIndex: Int
    let a: ScalarMeshPoint
    let b: ScalarMeshPoint
    let c: ScalarMeshPoint
    let low: ScalarMeshPoint
    let high: ScalarMeshPoint

    init(ids: SIMD3<UInt32>, points: [ScalarMeshPoint]) {
        self.init(ids: ids, a: points[Int(ids.x)], b: points[Int(ids.y)], c: points[Int(ids.z)])
    }

    init(ids: SIMD3<UInt32>, a: ScalarMeshPoint, b: ScalarMeshPoint, c: ScalarMeshPoint, sourceIndex: Int = 0) {
        self.ids = ids; self.a = a; self.b = b; self.c = c; self.sourceIndex = sourceIndex
        low = SIMD3(min(a.x, min(b.x, c.x)), min(a.y, min(b.y, c.y)), min(a.z, min(b.z, c.z)))
        high = SIMD3(max(a.x, max(b.x, c.x)), max(a.y, max(b.y, c.y)), max(a.z, max(b.z, c.z)))
    }

    var normal: ScalarMeshPoint {
        let ab = b - a, bc = c - b, ca = a - c
        let first = scalarMeshDot(ab, ab), second = scalarMeshDot(bc, bc), third = scalarMeshDot(ca, ca)
        if first <= second && first <= third {
            return scalarMeshCross(ab, c - a)
        }
        if second <= third {
            return scalarMeshCross(bc, a - b)
        }
        return scalarMeshCross(ca, b - c)
    }

    func point(_ index: Int) -> ScalarMeshPoint { index == 0 ? a : index == 1 ? b : c }

    /// Squared distance to a closed triangle, including its edges and vertices.
    func squaredDistance(_ p: ScalarMeshPoint) -> Double {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = scalarMeshDot(ab, ap), d2 = scalarMeshDot(ac, ap)
        if d1 <= 0 && d2 <= 0 {
            return scalarMeshDot(ap, ap)
        }
        let bp = p - b, d3 = scalarMeshDot(ab, bp), d4 = scalarMeshDot(ac, bp)
        if d3 >= 0 && d4 <= d3 {
            return scalarMeshDot(bp, bp)
        }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let delta = ap - ab * (d1 / (d1 - d3))
            return scalarMeshDot(delta, delta)
        }
        let cp = p - c, d5 = scalarMeshDot(ab, cp), d6 = scalarMeshDot(ac, cp)
        if d6 >= 0 && d5 <= d6 {
            return scalarMeshDot(cp, cp)
        }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let delta = ap - ac * (d2 / (d2 - d6))
            return scalarMeshDot(delta, delta)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
            let delta = bp - (c - b) * ((d4 - d3) / (d4 - d3 + d5 - d6))
            return scalarMeshDot(delta, delta)
        }
        let n = normal, distance = scalarMeshDot(n, ap)
        return distance * distance / scalarMeshDot(n, n)
    }

    /// Nil means this ray meets an edge/vertex or a numerically ambiguous plane.
    func rayHit(origin: ScalarMeshPoint, direction: ScalarMeshPoint) -> Bool? {
        let ab = b - a, ac = c - a, h = scalarMeshCross(direction, ac), determinant = scalarMeshDot(ab, h)
        let tolerance = 1e-12 * scalarMeshDot(normal, normal).squareRoot()
        if abs(determinant) <= tolerance {
            return abs(scalarMeshDot(normal, origin - a)) <= tolerance ? nil : false
        }
        let s = origin - a, u = scalarMeshDot(s, h) / determinant
        let q = scalarMeshCross(s, ab), v = scalarMeshDot(direction, q) / determinant
        let t = scalarMeshDot(ac, q) / determinant
        if t < 0 || u < -1e-12 || v < -1e-12 || u + v > 1 + 1e-12 {
            return false
        }
        if u <= 1e-12 || v <= 1e-12 || u + v >= 1 - 1e-12 {
            return nil
        }
        return true
    }
}

enum ScalarMeshIntersection {
    static func overlaps(_ first: ScalarMeshTriangle, _ second: ScalarMeshTriangle) -> Bool {
        let n1 = first.normal, n2 = second.normal
        if separated(first, second, axis: n1) || separated(first, second, axis: n2) {
            return false
        }
        for edge in 0..<3 {
            let a = first.point((edge + 1) % 3) - first.point(edge)
            if separated(first, second, axis: scalarMeshCross(n1, a)) {
                return false
            }
            for other in 0..<3 {
                let b = second.point((other + 1) % 3) - second.point(other)
                if separated(first, second, axis: scalarMeshCross(a, b)) {
                    return false
                }
            }
        }
        for edge in 0..<3 {
            let b = second.point((edge + 1) % 3) - second.point(edge)
            if separated(first, second, axis: scalarMeshCross(n2, b)) {
                return false
            }
        }
        var shared = SIMD3<Int32>(repeating: -1), count = 0
        for a in 0..<3 {
            for b in 0..<3 where first.ids[a] == second.ids[b] { shared[count] = Int32(a); count += 1 }
        }
        if count == 0 || count == 3 {
            return true
        }
        let line = scalarMeshCross(n1, n2)
        let parallel = scalarMeshDot(line, line) <= 1e-24 * scalarMeshDot(n1, n1) * scalarMeshDot(n2, n2)
        if !parallel {
            if count == 2 {
                return false
            }
            let common = first.point(Int(shared[0]))
            let firstInterval = interval(first, plane: n2, origin: common, line: line)
            let secondInterval = interval(second, plane: n1, origin: common, line: line)
            return min(firstInterval.y, secondInterval.y) > max(firstInterval.x, secondInterval.x)
        }
        // In one plane, only the common vertex/edge may touch. An edge crossing,
        // strict contained vertex or same-side shared edge means overlapping area.
        if count == 2 {
            let a = first.point(Int(shared[0])), b = first.point(Int(shared[1]))
            let side = scalarMeshCross(n1, b - a)
            var firstSide = 0.0, secondSide = 0.0
            for index in 0..<3 where first.ids[index] != first.ids[Int(shared[0])] && first.ids[index] != first.ids[Int(shared[1])] {
                firstSide = scalarMeshDot(side, first.point(index) - a)
            }
            for index in 0..<3 where second.ids[index] != first.ids[Int(shared[0])] && second.ids[index] != first.ids[Int(shared[1])] {
                secondSide = scalarMeshDot(side, second.point(index) - a)
            }
            return firstSide * secondSide >= 0
        }
        for index in 0..<3 {
            if first.ids[index] != first.ids[Int(shared[0])] && insideOrBoundary(first.point(index), second) {
                return true
            }
            if second.ids[index] != first.ids[Int(shared[0])] && insideOrBoundary(second.point(index), first) {
                return true
            }
        }
        for a in 0..<3 {
            for b in 0..<3 {
                let p = first.point(a), q = first.point((a + 1) % 3), r = second.point(b), s = second.point((b + 1) % 3)
                let firstSides = scalarMeshDot(n1, scalarMeshCross(q - p, r - p)) * scalarMeshDot(n1, scalarMeshCross(q - p, s - p))
                let secondSides = scalarMeshDot(n1, scalarMeshCross(s - r, p - r)) * scalarMeshDot(n1, scalarMeshCross(s - r, q - r))
                if firstSides < 0 && secondSides < 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func separated(_ a: ScalarMeshTriangle, _ b: ScalarMeshTriangle, axis: ScalarMeshPoint) -> Bool {
        if axis == .zero {
            return false
        }
        let a0 = scalarMeshDot(axis, a.a), a1 = scalarMeshDot(axis, a.b), a2 = scalarMeshDot(axis, a.c)
        let b0 = scalarMeshDot(axis, b.a), b1 = scalarMeshDot(axis, b.b), b2 = scalarMeshDot(axis, b.c)
        return max(a0, max(a1, a2)) < min(b0, min(b1, b2)) || max(b0, max(b1, b2)) < min(a0, min(a1, a2))
    }

    private static func interval(_ triangle: ScalarMeshTriangle, plane: ScalarMeshPoint, origin: ScalarMeshPoint, line: ScalarMeshPoint) -> SIMD2<Double> {
        var low = 0.0, high = 0.0
        for edge in 0..<3 {
            let a = triangle.point(edge) - origin, b = triangle.point((edge + 1) % 3) - origin
            let first = scalarMeshDot(plane, a), second = scalarMeshDot(plane, b)
            if first == 0 {
                let t = scalarMeshDot(a, line); low = min(low, t); high = max(high, t)
            } else if (first < 0 && second > 0) || (first > 0 && second < 0) {
                let point = a + (b - a) * (first / (first - second))
                let t = scalarMeshDot(point, line); low = min(low, t); high = max(high, t)
            }
        }
        return SIMD2(low, high)
    }

    private static func insideOrBoundary(_ p: ScalarMeshPoint, _ triangle: ScalarMeshTriangle) -> Bool {
        let n = triangle.normal
        let a = scalarMeshDot(n, scalarMeshCross(triangle.b - triangle.a, p - triangle.a))
        let b = scalarMeshDot(n, scalarMeshCross(triangle.c - triangle.b, p - triangle.b))
        let c = scalarMeshDot(n, scalarMeshCross(triangle.a - triangle.c, p - triangle.c))
        return (a >= 0 && b >= 0 && c >= 0) || (a <= 0 && b <= 0 && c <= 0)
    }
}
