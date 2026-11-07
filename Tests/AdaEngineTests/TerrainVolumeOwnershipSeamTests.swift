import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Owned volume tiles meet unchanged heightfield neighbors with identical explicit boundary segments")
    func volumeOwnershipConformsHeightfieldSeams() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var terrain = Terrain3D(resolution: 129, size: 128)
        for z in 0..<129 {
            for x in 0..<129 {
                terrain.heights[z * 129 + x] = 0.375 + Float(x) * 0.02 + Float(z) * 0.015 + ((x + z).isMultiple(of: 2) ? 0.15 : 0)
            }
        }
        let storage = try TerrainHeightStorage(importing: terrain)
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let operation = TerrainVolumeOperation(
            operation: .union,
            operand: .primitive(.box(halfExtents: [3, 0.5, 3])),
            transform: .init(translation: [-32, 20, -32])
        )
        let file = folder.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(
            regions,
            manifest: .init(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y),
            at: file.path,
            volume: .init(document: .init(cellSize: 1, origin: [-64, 0, -64], operations: [operation]), bricks: [])
        )
        let app = try await makeApp()
        let owner = app.main.spawn("Hybrid seam terrain") { Transform(); Terrain3DSource(source: file.path, streamingRadius: nil) }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        var descriptors: [TerrainTileCoordinate: MeshDescriptor] = [:]
        for child in owner.children {
            if let coordinate = child.components[TerrainTile3DComponent.self]?.coordinate,
                let descriptor = child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first?.meshDescriptor {
                descriptors[coordinate] = descriptor
            }
        }
        let owned = try #require(descriptors[.init(x: 0, z: 0)])
        let right = try #require(descriptors[.init(x: 1, z: 0)]), front = try #require(descriptors[.init(x: 0, z: 1)])
        let ownedX = volumeBoundarySegments(owned, axis: 0), ownedZ = volumeBoundarySegments(owned, axis: 2)
        #expect(!ownedX.isEmpty && !ownedZ.isEmpty)
        #expect(ownedX == volumeBoundarySegments(right, axis: 0), "Every X ownership boundary edge must have the same subdivision on both surfaces")
        #expect(ownedZ == volumeBoundarySegments(front, axis: 2), "Every Z ownership boundary edge must have the same subdivision on both surfaces")
    }

    private func volumeBoundarySegments(_ descriptor: MeshDescriptor, axis: Int) -> Set<String> {
        let positions = descriptor.positions.elements, indices = descriptor.indicies
        var result: Set<String> = []
        func key(_ point: Vector3) -> String {
            "\(Int((point.x * 100_000).rounded())),\(Int((point.y * 100_000).rounded())),\(Int((point.z * 100_000).rounded()))"
        }
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            for edge in 0..<3 {
                let a = positions[Int(indices[triangle + edge])], b = positions[Int(indices[triangle + (edge + 1) % 3])]
                if a[axis] == 0, b[axis] == 0, a != b {
                    let left = key(a), right = key(b)
                    result.insert(left < right ? left + ":" + right : right + ":" + left)
                }
            }
        }
        return result
    }
}
