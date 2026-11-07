@testable import AdaScene
import Math
import Testing

@Suite("Terrain camera LOD policy")
struct TerrainCameraLODTests {
    @Test("Distance bands retain detail across jitter, nearest views win, and inverse transforms preserve the policy")
    func bandsAndMultipleViews() throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let first = TerrainTileCoordinate(x: 0, z: 0), second = TerrainTileCoordinate(x: 1, z: 0)
        let coordinates = [first, second]
        func select(_ x: Float, previous: [TerrainTileCoordinate: TerrainLODSelection] = [:]) throws -> [TerrainTileCoordinate: TerrainLODSelection] {
            try TerrainCameraLOD.select(
                storage: storage,
                coordinates: coordinates,
                cameraPositions: [[x, 0, 32]],
                inverse: .identity,
                maximumLevel: 6,
                distance: 128,
                previous: previous
            )
        }
        let initial = try select(200)
        #expect(initial[first]?.level == 1)
        #expect(initial[first]?.finerEdges == .maxX)
        #expect(initial[second]?.level == 0)
        #expect(try select(190, previous: initial) == initial)
        let detailed = try select(160, previous: initial)
        #expect(detailed.values.allSatisfy { $0.level == 0 })
        #expect(try select(200, previous: detailed) == detailed)
        let coarseAgain = try select(220, previous: detailed)
        #expect(coarseAgain[first]?.level == 1)
        let matrix = Transform3D(translation: [10, 0, 20]) * Transform3D(scale: [-2, 1, 2])
        let reflected = try TerrainCameraLOD.select(
            storage: storage,
            coordinates: coordinates,
            cameraPositions: [[-430, 0, 84]],
            inverse: matrix.inverse,
            maximumLevel: 6,
            distance: 128,
            previous: [:]
        )
        #expect(reflected == coarseAgain)
        let twoViews = try TerrainCameraLOD.select(
            storage: storage,
            coordinates: coordinates,
            cameraPositions: [[10_000, 0, 0], [32, 0, 32]],
            inverse: .identity,
            maximumLevel: 6,
            distance: 128,
            previous: [:]
        )
        #expect(twoViews.values.allSatisfy { $0.level == 0 })
    }

    @Test("Partial tiles, no cameras and a zero level cap retain full detail")
    func conservativeCases() throws {
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 66, size: 65))
        let selected = try TerrainCameraLOD.select(
            storage: storage,
            coordinates: storage.tileCoordinates,
            cameraPositions: [[10_000, 0, 0]],
            inverse: .identity,
            maximumLevel: 6,
            distance: 128,
            previous: [:]
        )
        #expect(selected.count == 4 && selected.values.allSatisfy { $0.level == 0 && $0.finerEdges.isEmpty })
        let full = try TerrainHeightStorage()
        try full.allocateRegion(at: .init(x: 0, z: 0))
        let far = try TerrainCameraLOD.select(
            storage: full,
            coordinates: full.tileCoordinates,
            cameraPositions: [[10_000, 0, 0]],
            inverse: .identity,
            maximumLevel: 6,
            distance: 128,
            previous: [:]
        )
        #expect(far.values.allSatisfy { $0.level == 6 })
        let noCameras = try TerrainCameraLOD.select(
            storage: full,
            coordinates: full.tileCoordinates,
            cameraPositions: [],
            inverse: .identity,
            maximumLevel: 6,
            distance: 128,
            previous: far
        )
        #expect(noCameras.values.allSatisfy { $0.level == 0 })
        let capped = try TerrainCameraLOD.select(
            storage: full,
            coordinates: full.tileCoordinates,
            cameraPositions: [[10_000, 0, 0]],
            inverse: .identity,
            maximumLevel: 0,
            distance: 128,
            previous: far
        )
        #expect(capped.values.allSatisfy { $0.level == 0 })
    }
}
