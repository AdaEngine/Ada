import Math

enum TriangleSurfaceEditing {
    static func apply(_ operation: MeshTerrainModifierOperation, to input: TriangleSurface, operand: TriangleSurface,
                      budget: TriangleGeometryBudget) throws -> TriangleSurface {
        var result = input
        switch operation {
        case let .sculpt(center, radius, displacement):
            for index in result.positions.indices {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let distance = (result.positions[index] - center).length
                if distance < radius {
                    let t = 1 - distance / radius
                    result.positions[index] += displacement * (t * t * (3 - 2 * t))
                }
            }
            result.normals = []
        case let .conform(direction, distance, strength):
            let query = try TriangleSurfaceIndex(positions: operand.positions, indices: operand.indices, maximumBytes: budget.maximumBytes)
            for index in result.positions.indices {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let ray = Ray(origin: result.positions[index] - direction.normalized * distance, direction: direction.normalized)
                if let hit = try query.raycast(ray, maximumDistance: distance * 2) {
                    result.positions[index] += (hit.position - result.positions[index]) * strength
                }
            }
            result.normals = []
        case let .refine(length, iterations):
            for _ in 0..<iterations { result = try refine(result, maximumLength: length, bounds: operand.bounds, budget: budget) }
        case let .surfaceSculpt(stamp):
            result = try TriangleSheetSculpt.apply(stamp, to: input, budget: budget)
        case .union, .subtract: throw TriangleGeometryError.invalidInput
        }
        try result.validate(maximumTriangles: budget.maximumOutputTriangles)
        return result
    }

    private static func refine(_ input: TriangleSurface, maximumLength: Float, bounds: MeshTerrainBounds?, budget: TriangleGeometryBudget) throws -> TriangleSurface {
        var result = input
        var selected: Set<UInt64> = [], middle: [UInt64: UInt32] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(min(a, b)) << 32) | UInt64(max(a, b)) }
        for start in stride(from: 0, to: input.indices.count, by: 3) {
            for edge in 0..<3 {
                let a = input.indices[start + edge], b = input.indices[start + (edge + 1) % 3]
                let point = (input.positions[Int(a)] + input.positions[Int(b)]) * 0.5
                if bounds?.contains(point) != false, (input.positions[Int(a)] - input.positions[Int(b)]).length > maximumLength { selected.insert(key(a, b)) }
            }
        }
        guard !selected.isEmpty else { return input }
        func midpoint(_ a: UInt32, _ b: UInt32) throws -> UInt32? {
            let edge = key(a, b)
            guard selected.contains(edge) else { return nil }
            if let index = middle[edge] { return index }
            guard result.positions.count < budget.maximumBytes / 128 else { throw TriangleGeometryError.budgetExceeded }
            let index = UInt32(result.positions.count)
            result.positions.append((input.positions[Int(a)] + input.positions[Int(b)]) * 0.5)
            if !result.normals.isEmpty {
                let value = input.normals[Int(a)] + input.normals[Int(b)]
                result.normals.append(value.squaredLength > 0 ? value.normalized : .up)
            }
            if !result.textureCoordinates.isEmpty { result.textureCoordinates.append((input.textureCoordinates[Int(a)] + input.textureCoordinates[Int(b)]) * 0.5) }
            middle[edge] = index
            return index
        }
        result.indices = []; result.faceSources = []; result.faceIDs = []
        func append(_ ids: [UInt32], face: Int) throws {
            guard ids.count / 3 <= budget.maximumOutputTriangles - result.indices.count / 3 else { throw TriangleGeometryError.budgetExceeded }
            result.indices += ids
            result.faceSources += Array(repeating: input.faceSources.isEmpty ? 0 : input.faceSources[face], count: ids.count / 3)
            result.faceIDs += Array(repeating: input.faceIDs.isEmpty ? UInt32(face) : input.faceIDs[face], count: ids.count / 3)
        }
        for face in 0..<input.indices.count / 3 {
            if face.isMultiple(of: 256) { try Task.checkCancellation() }
            let a = input.indices[face * 3], b = input.indices[face * 3 + 1], c = input.indices[face * 3 + 2]
            let ab = try midpoint(a, b), bc = try midpoint(b, c), ca = try midpoint(c, a)
            switch (ab, bc, ca) {
            case let (.some(x), .some(y), .some(z)): try append([a, x, z, x, b, y, z, y, c, x, y, z], face: face)
            case let (.some(x), .some(y), nil): try append([a, x, c, x, y, c, x, b, y], face: face)
            case let (nil, .some(y), .some(z)): try append([b, y, a, y, z, a, y, c, z], face: face)
            case let (.some(x), nil, .some(z)): try append([c, z, b, z, x, b, z, a, x], face: face)
            case let (.some(x), nil, nil): try append([a, x, c, x, b, c], face: face)
            case let (nil, .some(y), nil): try append([b, y, a, y, c, a], face: face)
            case let (nil, nil, .some(z)): try append([c, z, b, z, a, b], face: face)
            default: try append([a, b, c], face: face)
            }
        }
        return result
    }
}
