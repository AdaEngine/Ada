import AdaScene
import Testing

@Suite("Terrain LOD balancing")
struct TerrainLODBalancerTests {
    @Test("Neighbor refinement propagates across a chain and produces directional seam masks")
    func propagatesRefinement() throws {
        var proposed: [TerrainTileCoordinate: Int] = [:]
        for x in 0...6 { proposed[.init(x: x, z: 0)] = x == 0 ? 0 : 6 }
        let selection = try TerrainLODBalancer.select(proposed: proposed)
        for x in 0...6 {
            let tile = try #require(selection[.init(x: x, z: 0)])
            #expect(tile.level == x)
            #expect(tile.finerEdges == (x == 0 ? [] : .minX))
        }
        let refined = try TerrainLODBalancer.select(proposed: proposed, fullDetailTiles: [.init(x: 3, z: 0)])
        let expected = [0, 1, 1, 0, 1, 2, 3]
        for x in 0...6 { #expect(refined[.init(x: x, z: 0)]?.level == expected[x]) }
    }

    @Test("A coarse center stitches all fine neighbors; partial topology holds itself and adjoining tiles at full detail")
    func neighborsAndPartialTiles() throws {
        let center = TerrainTileCoordinate(x: 0, z: 0)
        let neighbors: [TerrainTileCoordinate] = [.init(x: -1, z: 0), .init(x: 1, z: 0), .init(x: 0, z: -1), .init(x: 0, z: 1)]
        var proposed: [TerrainTileCoordinate: Int] = [center: 6]
        for neighbor in neighbors { proposed[neighbor] = 0 }
        let selected = try TerrainLODBalancer.select(proposed: proposed)
        #expect(selected[center]?.level == 1)
        #expect(selected[center]?.finerEdges == .all)
        for z in -1...1 { for x in -1...1 { proposed[.init(x: x, z: z)] = 6 } }
        let partial = try TerrainLODBalancer.select(proposed: proposed, partialTiles: [center])
        #expect(partial[center]?.level == 0)
        for neighbor in neighbors { #expect(partial[neighbor]?.level == 0) }
        #expect(partial[.init(x: -1, z: -1)]?.level == 1)
        #expect(partial[.init(x: 1, z: 1)]?.level == 1)
    }

    @Test("Disconnected islands retain their proposals, ordering is deterministic and extreme inputs stay bounded")
    func deterministicAndBounded() throws {
        let a = TerrainTileCoordinate(x: -16_384, z: -16_384)
        let b = TerrainTileCoordinate(x: 16_383, z: 16_383)
        let first = try TerrainLODBalancer.select(proposed: [a: 6, b: 0])
        let second = try TerrainLODBalancer.select(proposed: [b: 0, a: 6])
        #expect(first == second)
        #expect(first[a]?.level == 6 && first[a]?.finerEdges.isEmpty == true)
        #expect(throws: TerrainLODBalanceError.self) { try TerrainLODBalancer.select(proposed: [a: 7]) }
        #expect(throws: TerrainLODBalanceError.self) { try TerrainLODBalancer.select(proposed: [.init(x: .max, z: 0): 0]) }
        #expect(throws: TerrainLODBalanceError.self) { try TerrainLODBalancer.select(proposed: [:], partialTiles: [.init(x: 0, z: .min)]) }
    }
}
