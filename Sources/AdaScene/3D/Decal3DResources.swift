import AdaRender
import Math

@MainActor
enum Decal3DResources {
    static let maximumDecals = 8
    static let maximumScannedTriangles = 250_000
    static let maximumStampedTriangles = 8_192
    private static let atlasSide = 2_048
    private static let projectionWidth = 512
    private static let maximumExpandedBytes = 64 * 1024 * 1024

    private struct AtlasRegion {
        let x: Int
        let y: Int
        let image: Image

        func coordinates(width: Int, height: Int) -> Vector4 {
            Vector4(
                (Float(x) + 0.5) / Float(width),
                (Float(y) + 0.5) / Float(height),
                Float(image.width - 1) / Float(width),
                Float(image.height - 1) / Float(height)
            )
        }
    }

    static func validate(_ appearance: Decal3D.Appearance) throws(Decal3D.PlacementError) {
        for image in [appearance.color, appearance.normal, appearance.roughness].compactMap({ $0 }) {
            guard (1...atlasSide).contains(image.width), (1...atlasSide).contains(image.height),
                image.data.count == image.width * image.height * channelCount(image.format)
            else { throw .invalidAppearance }
        }
    }

    static func build(_ state: Decal3D.State, device: RenderDevice) throws(Decal3D.PlacementError) -> [Decal3DPartKey: Decal3DDraw] {
        let entries = state.entries.enumerated().sorted {
            let lhs = $0.element.appearance.priority, rhs = $1.element.appearance.priority
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        var parts: [Decal3DPartKey: Mesh.Part] = [:]
        for entry in entries {
            for (key, projection) in entry.projections {
                parts[key] = projection.part
            }
        }
        var remainingBytes = maximumExpandedBytes
        for part in parts.values {
            var layout = part.meshDescriptor.getMeshVertexBufferDescriptor()
            let stride = layout.layouts[0].stride
            let bytes = part.indexCount.multipliedReportingOverflow(by: stride)
            guard stride > 0, !bytes.overflow, bytes.partialValue <= remainingBytes else { throw .capacityExceeded }
            remainingBytes -= bytes.partialValue
        }
        let (atlas, regions) = try buildAtlas(entries.map(\.appearance))
        var draws: [Decal3DPartKey: Decal3DDraw] = [:]
        for (key, part) in parts {
            guard let vertices = state.draws[key]?.vertices ?? part.meshDescriptor.expandedTriangleVertices(
                renderDevice: device, maximumBytes: maximumExpandedBytes
            ) else { throw .unsupportedReceiver }
            let projection = projectionTexture(
                part.meshDescriptor.indicies,
                triangles: entries.map { $0.projections[key]?.triangles ?? [:] },
                regions: regions
            )
            draws[key] = Decal3DDraw(source: key, vertices: vertices, projection: projection, atlas: atlas)
        }
        return draws
    }

    private static func buildAtlas(_ appearances: [Decal3D.Appearance]) throws(Decal3D.PlacementError) -> (Texture2D, [Vector4]) {
        let images = appearances.flatMap { [$0.color, $0.normal, $0.roughness] }
        var x = 0, y = 0, row = 0, width = 1
        var regions: [Int: AtlasRegion] = [:]
        for (index, image) in images.enumerated().sorted(by: { ($0.element?.height ?? 0) > ($1.element?.height ?? 0) }) {
            guard let image else { continue }
            if x + image.width > atlasSide {
                y += row
                x = 0
                row = 0
            }
            guard y + image.height <= atlasSide else { throw .capacityExceeded }
            regions[index] = AtlasRegion(x: x, y: y, image: image)
            x += image.width
            width = max(width, x)
            row = max(row, image.height)
        }
        let height = max(1, y + row)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for region in regions.values {
            copy(region, into: &pixels, atlasWidth: width)
        }
        let atlas = Texture2D(descriptor: TextureDescriptor(
            width: width,
            height: height,
            pixelFormat: .rgba8,
            textureUsage: [.read],
            textureType: .texture2D,
            debugLabel: "Decal material atlas",
            samplerDescription: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped)
        ))
        upload(pixels, to: atlas, bytesPerRow: width * 4)
        let coordinates = images.indices.map { regions[$0]?.coordinates(width: width, height: height) ?? Vector4(-1, 0, 0, 0) }
        return (atlas, coordinates)
    }

    private static func channelCount(_ format: Image.Format) -> Int {
        switch format {
        case .rgba8, .bgra8, .bgra8_sRGB: 4
        case .rgb8: 3
        case .gray: 1
        }
    }

    private static func copy(_ region: AtlasRegion, into pixels: inout [UInt8], atlasWidth: Int) {
        let image = region.image
        let source = Array(image.data)
        let channels = channelCount(image.format)
        let swapsRedBlue = image.format == .bgra8 || image.format == .bgra8_sRGB
        for y in 0..<image.height {
            for x in 0..<image.width {
                let from = (y * image.width + x) * channels
                let to = ((region.y + y) * atlasWidth + region.x + x) * 4
                pixels[to] = source[from + (swapsRedBlue ? 2 : 0)]
                pixels[to + 1] = source[from + (channels == 1 ? 0 : 1)]
                pixels[to + 2] = source[from + (channels == 1 || swapsRedBlue ? 0 : 2)]
                pixels[to + 3] = channels == 4 ? source[from + 3] : 255
            }
        }
    }

    private static func projectionTexture(_ indices: [UInt32], triangles: [[Int: [Vector3]]], regions: [Vector4]) -> Texture2D {
        let faceCount = indices.count / 3
        // Two texels per source face: the range of ordered stamps, then the original morph vertex IDs.
        var table = [Vector4](repeating: .zero, count: faceCount * 2)
        for face in 0..<faceCount {
            let first = table.count
            var count = 0
            for (entry, stamps) in triangles.enumerated() {
                guard let corners = stamps[face] else { continue }
                table.append(contentsOf: corners.map { Vector4($0, 0) })
                table.append(contentsOf: regions[(entry * 3)..<(entry * 3 + 3)])
                count += 1
            }
            let vertex = face * 3
            table[face * 2] = Vector4(Float(first), Float(count), 0, 0)
            table[face * 2 + 1] = Vector4(Float(indices[vertex]), Float(indices[vertex + 1]), Float(indices[vertex + 2]), 0)
        }
        let width = min(projectionWidth, table.count)
        let height = (table.count + width - 1) / width
        table.append(contentsOf: repeatElement(.zero, count: width * height - table.count))
        let texture = Texture2D(descriptor: TextureDescriptor(
            width: width,
            height: height,
            pixelFormat: .rgba_32f,
            textureUsage: [.read],
            textureType: .texture2D,
            debugLabel: "Decal triangle projection"
        ))
        upload(table, to: texture, bytesPerRow: width * MemoryLayout<Vector4>.stride)
        return texture
    }

    private static func upload<T>(_ pixels: [T], to texture: Texture2D, bytesPerRow: Int) {
        unsafe pixels.withUnsafeBytes {
            if let base = $0.baseAddress {
                unsafe texture.replaceRegion(RectInt(x: 0, y: 0, width: texture.width, height: texture.height), withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
    }
}
