@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorTerrainNoise: Sendable {
    var seed: UInt64 = 42
    var amplitude: Float = 12
    var frequency: Float = 0.035

    func height(x: Float, z: Float) -> Float {
        guard x.isFinite, z.isFinite, frequency.isFinite else {
            return 0
        }
        var result: Float = 0, weight: Float = 1, total: Float = 0
        var scale = Double(frequency)
        for octave in 0..<5 {
            result += value(Double(x) * scale, Double(z) * scale, seed: seed &+ UInt64(octave) &* 7919) * weight
            total += weight
            weight *= 0.5
            scale *= 2
        }
        return result / total * amplitude
    }

    private func value(_ x: Double, _ z: Double, seed: UInt64) -> Float {
        let ix = floor(x), iz = floor(z)
        var u = Float(x - ix), v = Float(z - iz)
        u = u * u * (3 - 2 * u); v = v * v * (3 - 2 * v)
        func coordinateBits(_ coordinate: Double) -> UInt64 {
            Int64(exactly: coordinate).map(UInt64.init(bitPattern:)) ?? coordinate.bitPattern
        }
        func hash(_ x: Double, _ z: Double) -> Float {
            var h = coordinateBits(x) &* 0x9e3779b97f4a7c15 ^ coordinateBits(z) &* 0xbf58476d1ce4e5b9 ^ seed
            h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
            h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
            h ^= h >> 31
            return Float(h & 0xffffff) / Float(0xffffff) * 2 - 1
        }
        let a = hash(ix, iz), b = hash(ix + 1, iz), c = hash(ix, iz + 1), d = hash(ix + 1, iz + 1)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }

    @concurrent
    static func generate(_ settings: Self, at file: URL, manifest: TerrainManifestAsset) async throws {
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        var regions: [TerrainRegionAsset] = []
        for reference in manifest.heightRegions {
            try Task.checkCancellation()
            if let region = try await cache.loadRegion(at: .init(x: Int(reference.x), z: Int(reference.z))) { regions.append(region) }
        }
        let storage = try TerrainHeightStorage(regions: regions, spacing: manifest.spacing, origin: [manifest.originX, manifest.originZ])
        guard storage.tileCoordinates.count <= 240 else { throw EditorTerrainResourceWriter.Failure.modelTooLarge }
        for coordinate in storage.tileCoordinates {
            guard let snapshot = storage.snapshot(of: coordinate) else { continue }
            for z in 0...snapshot.cellCountZ {
                try Task.checkCancellation()
                for x in 0...snapshot.cellCountX {
                    let point = TerrainGridPoint(x: coordinate.x * 64 + x, z: coordinate.z * 64 + z)
                    let height = settings.height(x: manifest.originX + Float(point.x) * manifest.spacing, z: manifest.originZ + Float(point.z) * manifest.spacing)
                    _ = try storage.setHeight(height, at: point)
                }
            }
        }
        regions = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: manifest, at: file.path, mode: .update(removing: []))
    }
}
