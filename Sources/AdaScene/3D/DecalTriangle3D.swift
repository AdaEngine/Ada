import Math

/// A stamp expressed in the barycentric coordinates of its source triangle.
enum DecalTriangle3D {
    private struct ClipVertex {
        let point: Vector3
        let weights: Vector3
    }

    struct Vertex {
        let weights: Vector3
        let uv: Vector2

        func position(on first: Vector3, _ second: Vector3, _ third: Vector3) -> Vector3 {
            first * weights.x + second * weights.y + third * weights.z
        }
    }

    /// Finds the footprint inside a projector whose volume is the unit cube centered at the origin.
    static func clip(_ first: Vector3, _ second: Vector3, _ third: Vector3) -> [Vertex] {
        let corners = [first, second, third]
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return []
        }
        let axes = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
        var polygon = zip(corners, axes).map { ClipVertex(point: $0.0, weights: $0.1) }
        for axis in axes {
            polygon = clip(polygon, against: axis)
            polygon = clip(polygon, against: -axis)
        }
        guard let origin = polygon.first, var previous = polygon.last else {
            return []
        }
        var doubleArea = 0.0
        for vertex in polygon {
            let firstX = Double(previous.point.x) - Double(origin.point.x)
            let firstY = Double(previous.point.y) - Double(origin.point.y)
            let secondX = Double(vertex.point.x) - Double(origin.point.x)
            let secondY = Double(vertex.point.y) - Double(origin.point.y)
            doubleArea += firstX * secondY - firstY * secondX
            previous = vertex
        }
        guard doubleArea != 0 else {
            return []
        }
        return polygon.map {
            Vertex(weights: $0.weights, uv: Vector2(($0.point.x + 1) * 0.5, (1 - $0.point.y) * 0.5))
        }
    }

    private static func clip(_ polygon: [ClipVertex], against axis: Vector3) -> [ClipVertex] {
        guard var previous = polygon.last else {
            return []
        }
        var previousDistance = 1 - Double(previous.point.dot(axis))
        var clipped: [ClipVertex] = []
        for vertex in polygon {
            let distance = 1 - Double(vertex.point.dot(axis))
            if (distance < 0 && previousDistance > 0) || (distance > 0 && previousDistance < 0) {
                let fraction = previousDistance / (previousDistance - distance)
                let first = previous.point
                let second = vertex.point
                let complement = 1 - fraction
                clipped.append(ClipVertex(
                    point: Vector3(
                        axis.x != 0 ? axis.x : Float(Double(first.x) * complement + Double(second.x) * fraction),
                        axis.y != 0 ? axis.y : Float(Double(first.y) * complement + Double(second.y) * fraction),
                        axis.z != 0 ? axis.z : Float(Double(first.z) * complement + Double(second.z) * fraction)
                    ),
                    weights: previous.weights * Float(complement) + vertex.weights * Float(fraction)
                ))
            }
            if distance >= 0 {
                clipped.append(vertex)
            }
            previous = vertex
            previousDistance = distance
        }
        return clipped
    }
}
