@_spi(Internal) import AdaRender
import Math

/// Local shading data shared by all Vulkan instances of a part. Stable slots let a streamed terrain tile
/// replace its own range while in-flight and newly prepared views keep addressing the rest of the forest.
struct PathTracing3DGeometryTable: Sendable {
    struct Key: Hashable, Sendable {
        let part: PathTracing3DPartKey
        let uvLayout: UInt64
        var count: Int { part.indexCount / 3 }
    }

    private struct Block: Sendable {
        // Retain the input buffers whose identities form the cache key, including across preparation frames.
        var part: Mesh.Part
        var words: [Vector4]
    }
    private(set) var offsets: [Key: Int] = [:]
    private var blocks: [Key: Block] = [:]
    private var dirty: Set<Key> = []
    private(set) var texture: Texture2D?
    private var end = 0

    mutating func layout(_ keys: [Key], limit: Int) throws {
        let required = Set(keys)
        if required.count == offsets.count, keys.allSatisfy({ offsets[$0] != nil }) {
            return
        }
        guard keys.reduce(0, { $0 + $1.count }) <= limit else {
            throw PathTracing3DError.unsupported("Path tracing unique geometry exceeds the hardware shading table capacity")
        }
        offsets = offsets.filter { required.contains($0.key) }
        blocks = blocks.filter { required.contains($0.key) }
        dirty = dirty.intersection(required)
        var gaps: [Range<Int>] = []
        end = 0
        for (key, first) in offsets.sorted(by: { $0.value < $1.value }) {
            if end < first { gaps.append(end..<first) }
            end = first + key.count
        }
        for key in keys where offsets[key] == nil {
            if let hole = gaps.firstIndex(where: { $0.count >= key.count }) {
                let gap = gaps[hole]
                offsets[key] = gap.lowerBound
                gaps[hole] = (gap.lowerBound + key.count)..<gap.upperBound
            } else {
                offsets[key] = end
                end += key.count
            }
        }
        if end > limit {
            end = 0
            for key in keys {
                if offsets[key] != end { dirty.insert(key) }
                offsets[key] = end
                end += key.count
            }
        }
    }

    func contains(_ key: Key) -> Bool { blocks[key] != nil }

    /// Pack one shared mesh in primitive-index order. The GPU supplies the transform, material and flags for each hit.
    mutating func pack(_ part: Mesh.Part, material: PBRMaterial, key: Key) -> Int {
        let descriptor = part.meshDescriptor
        let positions = descriptor.positions.elements
        let normals = descriptor.normals?.elements ?? []
        let uv0 = descriptor.textureCoordinates?.elements ?? []
        let uv1 = descriptor[MeshDescriptor.textureCoordinates1]?.elements ?? []
        let maps = (0..<5).map { slot in
            let t = material.textureTransforms.indices.contains(slot) ? material.textureTransforms[slot] : PBRTextureTransform.identity
            let coordinate = material.textureCoordinates.indices.contains(slot) ? material.textureCoordinates[slot] : 0
            return (second: coordinate == 1, t: t, cos: Math.cos(t.rotation), sin: Math.sin(t.rotation))
        }
        func uv(_ i: Int, _ slot: Int) -> Vector2 {
            let map = maps[slot]
            let buffer = map.second ? uv1 : uv0
            let v = buffer.indices.contains(i) ? buffer[i] : .zero
            if map.t == .identity {
                return v
            }
            let x = v.x * map.t.scale.x
            let y = v.y * map.t.scale.y
            return Vector2(x * map.cos - y * map.sin, x * map.sin + y * map.cos) + map.t.offset
        }
        let terrain = material.terrainBindings != nil
        var words: [Vector4] = []
        words.reserveCapacity(key.count * 12)
        let indices = descriptor.indicies
        var references = 0
        for start in stride(from: 0, to: key.count * 3, by: 3) {
            let a = Int(indices[start])
            let b = Int(indices[start + 1])
            let c = Int(indices[start + 2])
            guard positions.indices.contains(a), positions.indices.contains(b), positions.indices.contains(c) else {
                words.append(contentsOf: repeatElement(.zero, count: 12))
                continue
            }
            references += 3
            for i in [a, b, c] { words.append(Vector4(positions[i], 0)) }
            for i in [a, b, c] { words.append(Vector4(normals.indices.contains(i) ? normals[i] : .zero, 0)) }
            for i in [a, b, c] {
                let base = uv(i, 0)
                let other = terrain ? (uv1.indices.contains(i) ? uv1[i] : .zero) : uv(i, 1)
                words.append(Vector4(base.x, base.y, other.x, other.y))
            }
            for i in [a, b, c] {
                let e = uv(i, 4)
                let n = uv(i, 2)
                words.append(Vector4(e.x, e.y, n.x, n.y))
            }
        }
        blocks[key] = Block(part: part, words: words)
        dirty.insert(key)
        return references
    }

    mutating func upload(maximumWords: Int?) -> Bool {
        let width = PathTracing3DScene.dataWidth
        let needed = max(1, (end * 12 + width - 1) / width)
        let oldHeight = texture?.height ?? 0
        if oldHeight < needed || (oldHeight > 16 && needed < oldHeight / 4) {
            let height = min(8192, needed + needed / 8)
            texture = Texture2D(
                descriptor: .init(
                    width: width,
                    height: height,
                    pixelFormat: .rgba_32f,
                    textureUsage: [.read],
                    textureType: .texture2D,
                    debugLabel: "Path tracing local-space triangles"
                )
            )
            dirty = Set(blocks.keys)
        }
        guard let texture, !dirty.isEmpty else {
            return true
        }
        // Coalesce adjacent dirty parts into bounded uploads. A small LOD replacement writes only its own texels.
        var start = 0
        var pending: [Vector4] = []
        var sent = 0
        for (key, first) in offsets.filter({ dirty.contains($0.key) }).sorted(by: { $0.value < $1.value }) {
            guard let words = blocks[key]?.words else { continue }
            if let maximumWords, sent > 0, words.count > maximumWords - sent { break }
            sent += words.count
            dirty.remove(key)
            let next = first * 12
            if !pending.isEmpty && (start + pending.count != next || pending.count >= 262_144) {
                Self.upload(pending, at: start, to: texture)
                pending = []
            }
            if pending.isEmpty {
                start = next
                pending = words
            } else {
                pending.append(contentsOf: words)
            }
        }
        Self.upload(pending, at: start, to: texture)
        return dirty.isEmpty
    }

    private static func upload(_ words: [Vector4], at start: Int, to texture: Texture2D) {
        let width = PathTracing3DScene.dataWidth
        unsafe words.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            var done = 0
            while done < words.count {
                let first = start + done
                let x = first % width
                let remaining = words.count - done
                let columns = min(width - x, remaining)
                let rows = columns == width ? remaining / width : 1
                let stride = MemoryLayout<Vector4>.stride
                unsafe texture.replaceRegion(
                    .init(x: x, y: first / width, width: columns, height: rows),
                    withBytes: base.advanced(by: done * stride),
                    bytesPerRow: columns * stride
                )
                done += columns * rows
            }
        }
    }
}
