import AdaECS
import AdaRender
import AdaSprite
import AdaTransform
import Math

/// Retains immutable chunk identity and its world transform; shared maps cache each owner independently.
final class TileMapOcclusionGeometry: Sendable {
    let chunk: TileMapRenderedChunk
    let model: Transform3D
    let polygons: [ExtractedOccluder2DInstance]

    init(chunk: TileMapRenderedChunk, model: Transform3D) {
        self.chunk = chunk
        self.model = model
        self.polygons = chunk.occluderPolygons.compactMap { points in
            var ring = points.map { point in
                let transformed = model * Vector4(point.x, point.y, chunk.bounds.center.z, 1)
                return Vector2(transformed.x, transformed.y)
            }
            guard ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                return nil
            }
            var area: Double = 0
            for index in 1..<(ring.count - 1) {
                let a = ring[index] - ring[0], b = ring[index + 1] - ring[0]
                area += Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x)
            }
            guard abs(area) > 1e-10 else {
                return nil
            }
            if area < 0 { ring.reverse() }
            return ExtractedOccluder2DInstance(worldPointsCCW: ring)
        }
    }
}

struct TileMapOcclusionCache: Resource {
    var geometries: [ObjectIdentifier: TileMapOcclusionGeometry] = [:]
    var rebuiltChunks = 0
}

// Lighting clears its extraction first. Offscreen walls must still cast shadows into the view.
@PlainSystem(dependencies: [.after(ExtractLighting2DSystem.self)])
struct ExtractTileMapOccludersSystem {
    @Extract<Query<TileMapComponent, GlobalTransform, Visibility>> private var maps
    @ResMut<ExtractedLighting2D> private var lighting
    @ResMut<TileMapOcclusionCache> private var cache

    init(world: World) {
        if world.getResource(ExtractedLighting2D.self) == nil { world.insertResource(ExtractedLighting2D()) }
        if world.getResource(TileMapOcclusionCache.self) == nil { world.insertResource(TileMapOcclusionCache()) }
    }

    func update(context _: UpdateContext) {
        cache.rebuiltChunks = 0
        var active: Set<ObjectIdentifier> = []
        maps.wrappedValue.forEach { component, transform, visibility in
            guard visibility != .hidden else {
                return
            }
            for layer in component.tileMap.layers where layer.isEnabled {
                for chunk in component.renderedChunks[layer.id]?.values ?? [:].values where !chunk.occluderPolygons.isEmpty {
                    let key = ObjectIdentifier(chunk)
                    active.insert(key)
                    if cache.geometries[key]?.model != transform.matrix {
                        cache.geometries[key] = TileMapOcclusionGeometry(chunk: chunk, model: transform.matrix)
                        cache.rebuiltChunks += 1
                    }
                    if let geometry = cache.geometries[key] { lighting.occluders.append(contentsOf: geometry.polygons) }
                }
            }
        }
        for key in Array(cache.geometries.keys) where !active.contains(key) { cache.geometries[key] = nil }
    }
}
