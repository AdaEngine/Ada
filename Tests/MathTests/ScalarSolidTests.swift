import Math
import Testing

@Suite("Analytic scalar solid operands")
struct ScalarSolidTests {
    @Test("Sphere, box and capsule expose negative-inside analytic samples")
    func primitiveValues() throws {
        let sphere = try ScalarSolid(primitive: .sphere(radius: 2))
        #expect(try sphere.value(at: .zero) == -2)
        #expect(try sphere.value(at: [2, 0, 0]) == 0)
        #expect(try sphere.value(at: [3, 0, 0]) == 1)
        let box = try ScalarSolid(primitive: .box(halfExtents: [1, 2, 3]))
        #expect(try box.value(at: .zero) == -1)
        #expect(try box.value(at: [2, 2, 3]) == 1)
        #expect(abs(try box.value(at: [2, 3, 4]) - Float(3).squareRoot()) < 0.00001)
        let capsule = try ScalarSolid(primitive: .capsule(radius: 1, halfHeight: 2))
        #expect(try capsule.value(at: .zero) == -1)
        #expect(try capsule.value(at: [0, 3, 0]) == 0)
        #expect(try capsule.value(at: [0, 4, 0]) == 1)
    }

    @Test("Reflected nonuniform and sheared transforms preserve solid membership and contain the surface", arguments: [false, true])
    func affinePlacement(shear: Bool) throws {
        var matrix = Transform3D(translation: [3, 2, -4], rotation: Quat(axis: .right, angle: .pi / 2), scale: [-2, 1.5, 0.5])
        if shear { matrix.y += matrix.x * 0.25 }
        let solid = try ScalarSolid(primitive: .sphere(radius: 2), transform: matrix)
        #expect(try solid.value(at: (matrix * Vector4(0, 0, 0, 1)).xyz) < 0)
        #expect(try solid.value(at: (matrix * Vector4(3, 0, 0, 1)).xyz) > 0)
        for point in [Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, -2)] {
            let world = (matrix * Vector4(point, 1)).xyz
            #expect(abs(try solid.value(at: world)) < 0.00001)
            #expect(world.x >= solid.bounds.min.x && world.x <= solid.bounds.max.x)
            #expect(world.y >= solid.bounds.min.y && world.y <= solid.bounds.max.y)
            #expect(world.z >= solid.bounds.min.z && world.z <= solid.bounds.max.z)
        }
    }

    @Test("Invalid dimensions, placement, points and nonfinite Boolean inputs fail explicitly")
    func rejectsInvalidOperands() throws {
        for primitive in [ScalarSolidPrimitive.sphere(radius: 0), .box(halfExtents: [1, -1, 1]), .capsule(radius: 1, halfHeight: -.infinity)] {
            #expect(throws: ScalarSolidError.invalidPrimitive) { try ScalarSolid(primitive: primitive) }
        }
        #expect(throws: ScalarSolidError.invalidTransform) { try ScalarSolid(primitive: .sphere(radius: 1), transform: .init(scale: [0, 1, 1])) }
        var projective = Transform3D.identity
        projective.x.w = 0.1
        #expect(throws: ScalarSolidError.invalidTransform) { try ScalarSolid(primitive: .sphere(radius: 1), transform: projective) }
        let solid = try ScalarSolid(primitive: .sphere(radius: 1))
        #expect(throws: ScalarSolidError.invalidPoint) { try solid.value(at: [.nan, 0, 0]) }
        #expect(throws: ScalarSolidError.invalidDensity) { try ScalarBooleanOperation.union.apply(base: -.infinity, operand: 0) }
    }

    @Test("Ordered primitive subtraction and union extract a closed tunnel and added ledge")
    func primitiveTunnelAndLedge() throws {
        let base = try ScalarSolid(primitive: .box(halfExtents: [8, 3, 8]), transform: .init(translation: [16, 0, 16]))
        let cut = try ScalarSolid(
            primitive: .capsule(radius: 2, halfHeight: 12),
            transform: .init(translation: [16, 0, 16], rotation: Quat(axis: .right, angle: .pi / 2), scale: .one)
        )
        let ledge = try ScalarSolid(primitive: .box(halfExtents: [4, 1, 4]), transform: .init(translation: [24, 4, 16]))
        func density(_ point: Vector3) throws -> Float {
            let carved = try ScalarBooleanOperation.subtract.apply(base: base.value(at: point), operand: cut.value(at: point))
            return try ScalarBooleanOperation.union.apply(base: carved, operand: ledge.value(at: point))
        }
        #expect(try density([16, 0, 16]) > 0)
        #expect(try density([20, 0, 16]) < 0)
        #expect(try density([26, 4, 16]) < 0)
        #expect(try density([16, 7, 16]) > 0)
        var values: [Float] = []
        for z in 0...32 {
            for y in 0...16 {
                for x in 0...32 { values.append(try density([Float(x), Float(y) - 8, Float(z)])) }
            }
        }
        let grid = try ScalarFieldGrid(origin: [0, -8, 0], spacing: 1, cellCount: [32, 16, 32], values: values)
        let mesh = try ScalarFieldSurface.extract(grid)
        try #require(!mesh.indices.isEmpty)
        var edges: [UInt64: Int] = [:]
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            for corner in 0..<3 {
                let a = mesh.indices[index + corner], b = mesh.indices[index + (corner + 1) % 3]
                edges[(UInt64(min(a, b)) << 32) | UInt64(max(a, b)), default: 0] += 1
            }
        }
        #expect(edges.values.allSatisfy { $0 == 2 })
        #expect(mesh.positions.contains { $0.x > 24 && $0.y > 3 })
        #expect(mesh.positions.contains { $0.z > 12 && $0.z < 20 && abs($0.x - 16) < 2.1 && abs($0.y) < 2.1 })
    }
}
