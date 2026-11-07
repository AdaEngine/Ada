import AdaAssets
import AdaScene
import Foundation
import Math
import Testing

@Suite("Volume field bounded worker interactions")
struct TerrainVolumeFieldEdgeTests {
    private func base() throws -> TerrainHeightStorage { try .init(importing: Terrain3D(resolution: 65, size: 64)) }

    @Test("Mesh voxelization discards budget-exhausted work and can build the complete generation afterward")
    func importedBrickWork() throws {
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "Models/solid.obj", scene: nil), transform: .init(translation: [8, 3, 8]), layerID: 9)
        let mesh = try TerrainVolumePreparedMesh(
            operation: operation,
            positions: [[0, 0, 0], [6, 0, 0], [0, 6, 0], [0, 0, 6]],
            indices: [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        )
        let source = try base(), revision = source.revision
        let field = try TerrainVolumeField(document: .init(cellSize: 1, operations: [operation]), base: source, preparedMeshes: [mesh])
        #expect(throws: TerrainVolumeFieldError.workBudgetExceeded) { try field.makeBrick(x: 0, y: 0, z: 0, maximumWork: 40_000) }
        #expect(source.revision == revision)
        let brick = try field.makeBrick(x: 0, y: 0, z: 0)
        let index = (9 * 33 + 4) * 33 + 9
        #expect(brick.values[index] < 0 && brick.materialTags[index] == 9)
        let surface = try field.surface(of: brick)
        #expect(surface.positions.contains { $0.y > 3 })
    }

    @Test("Fractional lattice origins and negative addresses retain shared samples on every axis")
    func fractionalSeams() throws {
        let field = try TerrainVolumeField(document: .init(cellSize: 0.3, origin: [0.17, 0.11, -0.23]), base: base())
        let first = try field.makeBrick(x: -1, y: -1, z: -1)
        func index(_ point: SIMD3<Int>) -> Int { (point.z * 33 + point.y) * 33 + point.x }
        for axis in 0..<3 {
            var coordinate = SIMD3<Int32>(repeating: -1); coordinate[axis] = 0
            let other = try field.makeBrick(x: coordinate.x, y: coordinate.y, z: coordinate.z)
            for a in 0...32 {
                for b in 0...32 {
                    var point = SIMD3<Int>(repeating: 0)
                    point[axis] = 32; point[(axis + 1) % 3] = a; point[(axis + 2) % 3] = b
                    let from = index(point); point[axis] = 0
                    #expect(first.values[from].bitPattern == other.values[index(point)].bitPattern)
                    #expect(first.materialTags[from] == other.materialTags[index(point)])
                }
            }
        }
    }

    @Test("Disabled missing mesh sources do not evaluate and a cancelled brick build throws")
    func disabledAndCancelled() async throws {
        let operation = TerrainVolumeOperation(operation: .subtract, operand: .mesh(assetPath: "Models/off.glb", scene: nil), isEnabled: false)
        let field = try TerrainVolumeField(document: .init(cellSize: 1, operations: [operation]), base: base())
        #expect(try field.sample(at: [0, -1, 0]).value < 0)
        let gate = VolumeFieldGate()
        let task = Task {
            await gate.wait()
            return try field.makeBrick(x: 0, y: 0, z: 0)
        }
        task.cancel(); await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor VolumeFieldGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !opened else {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
