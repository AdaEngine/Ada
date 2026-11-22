@_spi(Internal) import AdaRender
import Foundation
import Math

enum PathTracingTextureKey: Hashable, Sendable {
    case material(ObjectIdentifier)
    case terrain(UUID, family: Int, layer: Int)
}

enum PathTracingTextureInput: Sendable {
    case material(Texture2D)
    case terrain(UUID, family: Int, layer: Int, Image)

    var key: PathTracingTextureKey {
        switch self {
        case .material(let texture):
            .material(ObjectIdentifier(texture))
        case let .terrain(paletteID, family, layer, _):
            .terrain(paletteID, family: family, layer: layer)
        }
    }
}

/// Packs the exact raster ID, weight and paint texels. The field offsets fit exactly in f32.
struct PathTracingTerrainMaterials: Sendable {
    private static let maximumFieldTexels = 2048 * 8192
    private static let maximumHeaderVectors = 524_288
    private var fields = Data()
    private var headers: [Vector4] = []
    private var offsets: [ObjectIdentifier: Int] = [:]
    private var retainedFields: [TerrainMaterialBindings] = []
    private var regularKeys: [PathTracingTextureKey] = []
    private var atlasInputs: [PathTracingTextureInput] = []
    private(set) var texture: Texture2D?

    mutating func prepare(
        _ materials: [PBRMaterial],
        textures: inout [PathTracingTextureInput],
        ids: inout [PathTracingTextureKey: Int]
    ) throws {
        let bindings = materials.compactMap(\.terrainBindings)
        guard !bindings.isEmpty else {
            self = Self()
            return
        }
        let keys = textures.map(\.key)
        if keys == regularKeys && bindings.elementsEqual(retainedFields, by: { $0 === $1 }) {
            for input in atlasInputs {
                ids[input.key] = textures.count
                textures.append(input)
            }
            return
        }
        var new = Self()
        new.regularKeys = keys
        new.retainedFields = bindings
        for binding in bindings {
            try new.register(binding, textures: &textures, ids: &ids)
        }
        new.atlasInputs = Array(textures.dropFirst(keys.count))
        if !new.fields.isEmpty {
            let width = 2048
            let rows = (new.fields.count / 4 + width - 1) / width
            new.fields.count = rows * width * 4
            // Data fields have no alpha semantics and never need a CPU picking mask.
            let texture = Texture2D(
                descriptor: .init(
                    width: width,
                    height: rows,
                    pixelFormat: .rgba8,
                    textureUsage: [.read],
                    textureType: .texture2D,
                    debugLabel: "Path tracing terrain fields"
                )
            )
            unsafe new.fields.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    unsafe texture.replaceRegion(.init(x: 0, y: 0, width: width, height: rows), withBytes: base, bytesPerRow: width * 4)
                }
            }
            new.texture = texture
        }
        new.fields = Data()
        self = new
    }

    func address(of bindings: TerrainMaterialBindings?) -> Float {
        guard let bindings else {
            return 0
        }
        return Float(offsets[ObjectIdentifier(bindings)] ?? 0)
    }

    private mutating func register(
        _ bindings: TerrainMaterialBindings,
        textures: inout [PathTracingTextureInput],
        ids: inout [PathTracingTextureKey: Int]
    ) throws {
        let key = ObjectIdentifier(bindings)
        guard offsets[key] == nil else {
            return
        }
        guard let field = bindings.tracingField, field.parameters.count == 129,
            let grid = field.parameters.first, grid.w.isFinite, (1...32).contains(grid.w),
            grid.w.rounded() == grid.w
        else {
            throw PathTracing3DError.unsupported("The terrain's authored material fields are unavailable for hardware path tracing")
        }
        let layerCount = Int(grid.w)
        let maps = bindings.maps.tracingImages
        let width = field.layerIDs.width
        let height = field.layerIDs.height
        guard maps.count == 3, maps.allSatisfy({ $0.count == layerCount }),
            width > 0, height > 0, width <= Self.maximumFieldTexels / height,
            field.weights.width == width, field.weights.height == height
        else {
            throw PathTracing3DError.unsupported("The terrain material field or palette has invalid dimensions")
        }
        if let surface = field.surface, surface.width != width || surface.height != height * 2 {
            throw PathTracing3DError.unsupported("The terrain material field or palette has invalid dimensions")
        }
        // A valid single-layer palette always resolves to that layer, so only optional paint needs texels.
        let layerIDs = layerCount == 1 ? -1 : try append(field.layerIDs)
        let weights = layerCount == 1 ? -1 : try append(field.weights)
        let surface = try field.surface.map { try append($0) } ?? -1
        guard headers.count <= Self.maximumHeaderVectors - (3 + layerCount * 5) else {
            throw PathTracing3DError.unsupported("Path tracing terrain palette budget exceeded (8 MiB)")
        }
        let offset = headers.count + 1
        offsets[key] = offset
        headers += [grid, [Float(layerIDs), Float(weights), Float(width), Float(height)], [Float(surface), 0, 0, 0]]
        for layer in 0..<layerCount {
            let atlasTiles = maps.enumerated().map { family, images -> Float in
                let input = PathTracingTextureInput.terrain(bindings.maps.sourceID, family: family, layer: layer, images[layer])
                if let index = ids[input.key] {
                    return Float(index)
                }
                let index = textures.count
                ids[input.key] = index
                textures.append(input)
                return Float(index)
            }
            headers.append(field.parameters[1 + layer])
            headers.append(field.parameters[33 + layer])
            headers.append(field.parameters[65 + layer])
            headers.append(field.parameters[97 + layer])
            headers.append(Vector4(atlasTiles[0], atlasTiles[1], atlasTiles[2], 0))
        }
    }

    private mutating func append(_ image: Image) throws -> Int {
        let start = fields.count / 4
        guard image.width > 0, image.height > 0,
            image.width <= (Self.maximumFieldTexels - start) / image.height
        else {
            throw PathTracing3DError.unsupported("Path tracing terrain field budget exceeded (64 MiB)")
        }
        guard image.format == .rgba8, image.data.count == image.width * image.height * 4 else {
            throw PathTracing3DError.unsupported("Path tracing terrain fields require RGBA8 texels")
        }
        fields.append(image.data)
        return start
    }

    func appendHeaders(to materials: inout [Vector4]) {
        guard !headers.isEmpty else {
            return
        }
        let headerStart = materials.count
        for index in stride(from: 4, to: headerStart, by: 5) where materials[index].z > 0 {
            materials[index].z += Float(headerStart - 1)
        }
        materials.append(contentsOf: headers)
    }
}
