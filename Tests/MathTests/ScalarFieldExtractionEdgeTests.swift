import Math
import Testing

@Suite("Scalar extraction precision and cancellation")
struct ScalarFieldExtractionEdgeTests {
    private func sphere(scale: Float) throws -> ScalarFieldGrid {
        var values: [Float] = []
        for z in 0...32 {
            for y in 0...32 {
                for x in 0...32 {
                    let point = Vector3(Float(x) - 16.37, Float(y) - 16.21, Float(z) - 15.87)
                    values.append(point.dot(point) - 5.7 * 5.7)
                }
            }
        }
        return try .init(origin: [-16 * scale, -16 * scale, -16 * scale], spacing: scale, cellCount: [32, 32, 32], values: values)
    }

    @Test("Normals remain finite at scales where Float triangle-area arithmetic underflows or overflows", arguments: [Float(1e-20), Float(1e20)])
    func extremeCoordinateScale(scale: Float) throws {
        let mesh = try ScalarFieldSurface.extract(sphere(scale: scale))
        try #require(!mesh.indices.isEmpty)
        for (index, point) in mesh.positions.enumerated() {
            let normalizedPosition = point / scale - Vector3(0.37, 0.21, -0.13)
            #expect(point.x.isFinite && point.y.isFinite && point.z.isFinite)
            #expect(abs(normalizedPosition.length - 5.7) < 0.12)
            #expect(abs(mesh.normals[index].length - 1) < 0.001)
            #expect(mesh.normals[index].dot(normalizedPosition) > 5.7 * 0.95)
        }
    }

    @Test("Two solid half spaces sharing an exact zero plane do not extract internal duplicate sheets")
    func zeroContactPlane() throws {
        var values: [Float] = []
        for _ in 0...32 {
            for _ in 0...32 {
                for x in 0...32 { values.append(min(Float(x) - 16, 16 - Float(x))) }
            }
        }
        let grid = try ScalarFieldGrid(origin: .zero, spacing: 1, cellCount: [32, 32, 32], values: values)
        let mesh = try ScalarFieldSurface.extract(grid, maximumTriangles: 0)
        #expect(mesh.positions.isEmpty && mesh.normals.isEmpty && mesh.indices.isEmpty)
    }

    @Test("A cancelled authoring task never begins surface extraction")
    func cancellationBeforeExtraction() async throws {
        let grid = try sphere(scale: 1), gate = ExtractionGate()
        let work = Task {
            await gate.wait()
            return try ScalarFieldSurface.extract(grid)
        }
        work.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}

private actor ExtractionGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
