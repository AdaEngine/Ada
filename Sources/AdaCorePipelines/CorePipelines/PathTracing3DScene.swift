import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

enum PathTracing3DError: Error, CustomStringConvertible {
    case unsupported(String)
    case preparingGeometry
    var description: String {
        switch self {
        case .unsupported(let reason): reason
        case .preparingGeometry: "Preparing path tracing geometry"
        }
    }
}

/// CPU geometry is never camera culled. A light and its occluder can both be behind the camera.
struct PathTracing3DScene: Sendable {
    /// Non-shadow-casting graph cards/domes are cosmetic layers, composited after surface transport.
    static func isRasterOverlay(_ material: Material, castsShadows: Bool) -> Bool {
        !castsShadows && (material as? PBRMaterial)?.graphMaterial != nil
    }
    static let dataWidth = 2048
    private(set) var tileSize = 128
    static let atlasColumns = 16
    static let maximumTextures = 256
    static let maximumTriangles = 131072
    // An RGBA32F table 2048 texels wide and at most 8192 texels high, twelve texels per triangle.
    private static let maximumHardwareTriangles = dataWidth * 8192 / 12
    private static let maximumHardwareInstances = 1 << 20
    static let maximumMaterials = maximumTriangles * 2
    var nodes: Texture2D?
    var triangles: Texture2D?
    var materials: Texture2D?
    var atlas: Texture2D?
    var nodeCount = 0
    var triangleCount = 0
    var digest: UInt64?
    /// Counts every change of the prepared scene, including moving objects.
    var generation: UInt64 = 0
    /// Counts changes of the scene's content (meshes, instances, materials, textures, flags) but not of where things are.
    /// Denoisers keep their history across moving objects and restart it only when this changes.
    private(set) var structureGeneration: UInt64 = 0
    private var structureDigest: UInt64?
    /// One entry per placed part in table order, and the parts' geometry, for hardware ray queries (see `hardwareOrder`).
    private(set) var placements: [PathTracing3DPlacement] = []
    private(set) var parts: [PathTracing3DPartKey: Mesh.Part] = [:]
    /// True when the triangle table keeps one entry for every index-buffer triangle (degenerate ones as empty entries), so a
    /// hardware hit's primitive index addresses the table directly. The BVH is not built in this mode.
    private(set) var hardwareOrder = false
    private(set) var preparedVertexCount = 0
    private(set) var preparedPartVisitCount = 0
    private var images: [ObjectIdentifier: Image] = [:]
    private var textureOwners: [ObjectIdentifier: Texture2D] = [:]
    private var atlasKeys: [PathTracingTextureKey] = []
    private var terrainMaterials = PathTracingTerrainMaterials()
    var terrainFields: Texture2D? { terrainMaterials.texture }
    private var hardwareGeometry = PathTracing3DGeometryTable()
    private var placementDigests: [RID: (content: UInt64, motion: UInt64)] = [:]
    private var hierarchy = PathTracing3DBVH([])
    var geometryBounds: AABB? { hierarchy.nodes.first.map { AABB(min: $0.minimum, max: $0.maximum) } }

    private struct PreparedSource {
        let source: Mesh3DRenderSource
        let parts: [Mesh.Part]
    }

    private static func traceableParts(_ source: Mesh3DRenderSource) -> [Mesh.Part] {
        var parts: [Mesh.Part] = []
        for model in source.mesh.models {
            for part in model.parts {
                guard part.primitiveTopology == .triangleList, min(part.indexCount, part.meshDescriptor.indicies.count) >= 3,
                    source.materials.indices.contains(part.materialIndex),
                    !isRasterOverlay(source.materials[part.materialIndex], castsShadows: source.castShadows)
                else { continue }
                parts.append(part)
            }
        }
        return parts
    }

    mutating func prepare(
        _ sources: [Mesh3DRenderSource],
        skinning: Skinning3DUniforms?,
        device: RenderDevice,
        textureTileSize: Int = 128,
        hardwareOrder wantsHardwareOrder: Bool = false,
        hardwareTriangleStep: Int? = nil
    ) async throws {
        let preparedSources = sources.compactMap { source -> PreparedSource? in
            guard source.instances?.isEmpty != true else {
                return nil
            }
            let parts = Self.traceableParts(source)
            return parts.isEmpty ? nil : PreparedSource(source: source, parts: parts)
        }
        let sources = preparedSources.map(\.source)
        preparedVertexCount = 0
        preparedPartVisitCount = 0
        if wantsHardwareOrder {
            try Self.validateHardwareInstanceBudget(preparedSources)
        } else {
            try Self.validateWorkBudget(preparedSources)
        }
        var hash = FrameDigest3D()
        // Transforms and skinning poses: where things are, as opposed to what they are.
        var motion = FrameDigest3D()
        let requestedTileSize = textureTileSize >= 512 ? 512 : (textureTileSize >= 256 ? 256 : 128)
        hash.combine(UInt64(requestedTileSize))
        hash.combine(wantsHardwareOrder ? UInt64(1) : 0)
        var materialList: [PBRMaterial] = []
        var materialIDs: [RID: Int] = [:]
        var uvLayouts: [RID: UInt64] = [:]
        var newPlacementRevision = false
        var textures: [PathTracingTextureInput] = []
        var textureIDs: [PathTracingTextureKey: Int] = [:]
        for source in sources {
            guard source.morphBuffers.isEmpty else {
                throw PathTracing3DError.unsupported("Mesh morph targets are not supported by portable path tracing")
            }
            if source.skinningBuffer != nil && (skinning?.matrices(for: source.entity).isEmpty ?? true) {
                throw PathTracing3DError.unsupported("The current skinning palette is unavailable for path tracing")
            }
            hash.combine(UInt64(source.entity))
            motion.combine(source.transform)
            if wantsHardwareOrder { hash.combine(source.pathTracingMaximumDistance ?? 0) }
            hash.combine(UInt64(source.instances?.count ?? 1))
            hash.combine(source.instances == nil ? UInt64(0) : 1)
            if let instances = source.instances {
                let revision = source.instanceRevision
                if placementDigests[revision] == nil {
                    newPlacementRevision = true
                    var placementContent = FrameDigest3D()
                    var placementMotion = FrameDigest3D()
                    for instance in instances {
                        placementContent.combine(instance.id)
                        placementContent.combine(instance.color)
                        placementMotion.combine(instance.transform)
                    }
                    placementDigests[revision] = (placementContent.value, placementMotion.value)
                }
                if let cached = placementDigests[revision] {
                    hash.combine(cached.content)
                    motion.combine(cached.motion)
                }
            }
            hash.combine(source.castShadows ? UInt64(1) : 0)
            hash.combine(source.receiveShadows ? UInt64(1) : 0)
            if source.skinningBuffer != nil {
                for matrix in skinning?.matrices(for: source.entity) ?? [] { motion.combine(matrix) }
            }
            for model in source.mesh.models {
                for part in model.parts {
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.vertexBuffer).hashValue)))
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.indexBuffer).hashValue)))
                    hash.combine(UInt64(part.indexCount))
                }
            }
            for material in source.materials {
                if Self.isRasterOverlay(material, castsShadows: source.castShadows) { continue }
                guard let pbr = material as? PBRMaterial, pbr.graphMaterial == nil else {
                    throw PathTracing3DError.unsupported(
                        "Unsupported traced material \(String(reflecting:type(of:material))) on entity \(source.entity); shadow-casting shader graphs require a tracing material"
                    )
                }
                if let terrain = pbr.terrainBindings {
                    guard wantsHardwareOrder else {
                        throw PathTracing3DError.unsupported(
                            "Terrain material layers require raster rendering; portable path tracing uses the raster fallback for this view"
                        )
                    }
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(terrain).hashValue)))
                }
                if materialIDs[pbr.rid] == nil {
                    guard materialList.count < Self.maximumMaterials else { throw PathTracing3DError.unsupported("Path tracing material budget exceeded (262144)") }
                    materialIDs[pbr.rid] = materialList.count
                    materialList.append(pbr)
                    if wantsHardwareOrder {
                        var uvLayout = FrameDigest3D()
                        uvLayout.combine(pbr.terrainBindings == nil ? UInt64(0) : 1)
                        for transform in pbr.textureTransforms {
                            uvLayout.combine(Vector4(transform.offset.x, transform.offset.y, transform.scale.x, transform.scale.y))
                            uvLayout.combine(transform.rotation)
                        }
                        for coordinate in pbr.textureCoordinates { uvLayout.combine(UInt64(max(0, coordinate))) }
                        uvLayouts[pbr.rid] = uvLayout.value
                    }
                }
                hash.combine(pbr.baseColorFactor)
                hash.combine(Vector4(pbr.emissiveFactor, pbr.emissiveStrength))
                hash.combine(Vector4(pbr.metallicFactor, pbr.roughnessFactor, pbr.effectiveAlphaCutoff, pbr.normalScale))
                hash.combine(UInt64(pbr.effectiveAlphaMode.rawValue))
                hash.combine(pbr.effectiveDoubleSided ? UInt64(1) : 0)
                for transform in pbr.textureTransforms {
                    hash.combine(Vector4(transform.offset.x, transform.offset.y, transform.scale.x, transform.scale.y))
                    hash.combine(transform.rotation)
                }
                for coordinate in pbr.textureCoordinates { hash.combine(UInt64(max(0, coordinate))) }
                for texture in [pbr.baseColorTexture, pbr.metallicRoughnessTexture, pbr.emissiveTexture, pbr.normalTexture] {
                    guard let texture else {
                        hash.combine(UInt64(0))
                        continue
                    }
                    hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(texture).hashValue)))
                    let input = PathTracingTextureInput.material(texture)
                    if textureIDs[input.key] == nil {
                        textureIDs[input.key] = textures.count
                        textures.append(input)
                    }
                }
            }
        }
        var full = hash
        full.combine(motion.value)
        if newPlacementRevision || placementDigests.count > sources.count {
            let liveRevisions = Set(sources.lazy.filter { $0.instances != nil }.map(\.instanceRevision))
            placementDigests = placementDigests.filter { liveRevisions.contains($0.key) }
        }
        if digest == full.value {
            return
        }
        // After a partial upload, even a return to the preceding scene must reconcile its slots before tracing.
        digest = nil
        try terrainMaterials.prepare(materialList, textures: &textures, ids: &textureIDs)
        guard textures.count <= Self.maximumTextures else { throw PathTracing3DError.unsupported("Path tracing texture budget exceeded (256)") }
        try await prepareAtlas(textures, tileSize: requestedTileSize, device: device)
        func tile(_ texture: Texture2D?) -> Float { texture.flatMap { textureIDs[.material(ObjectIdentifier($0))] }.map(Float.init) ?? -1 }
        var materialData: [Vector4] = []
        for pbr in materialList {
            materialData += [
                pbr.baseColorFactor, Vector4(pbr.emissiveFactor * pbr.emissiveStrength, 0),
                Vector4(pbr.metallicFactor, pbr.roughnessFactor, pbr.effectiveAlphaCutoff, pbr.effectiveDoubleSided ? 1 : 0),
                Vector4(tile(pbr.baseColorTexture), tile(pbr.metallicRoughnessTexture), tile(pbr.emissiveTexture), tile(pbr.normalTexture)),
                Vector4(Float(pbr.effectiveAlphaMode.rawValue), pbr.normalScale, terrainMaterials.address(of: pbr.terrainBindings), 0),
            ]
        }
        struct TintKey: Hashable {
            let material: Int
            let tint: Vector4
        }
        var tintMaterials: [TintKey: Int] = [:]
        var geometry: [PathTracing3DBVH.Triangle] = []
        if wantsHardwareOrder {
            try prepareHardwareShading(preparedSources, uvLayouts: uvLayouts, hardwareTriangleStep: hardwareTriangleStep)
        }
        var instanceMetadata: [Vector4] = []
        var placedTriangleCount = 0
        var placed: [PathTracing3DPlacement] = []
        var placedParts: [PathTracing3DPartKey: Mesh.Part] = [:]
        for prepared in preparedSources {
            let source = prepared.source
            let palette = source.skinningBuffer == nil ? [] : skinning?.matrices(for: source.entity) ?? []
            for placement in 0..<(source.instances?.count ?? 1) {
                let transform = source.transform * (source.instances?[placement].transform ?? .identity)
                let tint = source.instances?[placement].color ?? .one
                let normalMatrix = wantsHardwareOrder ? Transform3D.identity : transform.inverse.transpose
                for part in prepared.parts {
                    preparedPartVisitCount += 1
                    guard let pbr = source.materials[part.materialIndex] as? PBRMaterial, let baseMaterial = materialIDs[pbr.rid]
                    else { continue }
                    let material: Int
                    if tint == .one {
                        material = baseMaterial
                    } else {
                        let key = TintKey(material: baseMaterial, tint: tint)
                        if let cached = tintMaterials[key] {
                            material = cached
                        } else {
                            material = materialData.count / 5
                            guard material < Self.maximumMaterials else { throw PathTracing3DError.unsupported("Path tracing tint material budget exceeded (262144)") }
                            let start = baseMaterial * 5
                            materialData.append(materialData[start] * tint)
                            for offset in 1..<5 {
                                let word = materialData[start + offset]
                                materialData.append(word)
                            }
                            tintMaterials[key] = material
                        }
                    }
                    let descriptor = part.meshDescriptor
                    if wantsHardwareOrder {
                        let key = PathTracing3DPartKey(part)
                        let shading = PathTracing3DGeometryTable.Key(part: key, uvLayout: uvLayouts[pbr.rid] ?? 0)
                        guard let first = hardwareGeometry.offsets[shading] else { continue }
                        placed.append(
                            PathTracing3DPlacement(
                                key: key,
                                transform: transform,
                                castsShadows: source.castShadows,
                                triangleCount: key.indexCount / 3
                            )
                        )
                        placedParts[key] = part
                        let flags = (source.castShadows ? 1 : 0) + (source.receiveShadows ? 2 : 0)
                        instanceMetadata.append(Vector4(Float(first), Float(material), Float(flags), source.pathTracingMaximumDistance ?? 0))
                        placedTriangleCount += key.indexCount / 3
                        continue
                    }
                    let sourcePositions = descriptor.positions.elements
                    let sourceNormals = descriptor.normals?.elements ?? []
                    let joints = descriptor[MeshDescriptor.jointIndices]?.elements
                    let weights = descriptor[MeshDescriptor.jointWeights]?.elements
                    let uv0 = descriptor.textureCoordinates?.elements ?? []
                    let uv1 = descriptor[MeshDescriptor.textureCoordinates1]?.elements ?? []
                    func vertex(_ i: Int) -> (position: Vector3, normal: Vector3) {
                        preparedVertexCount += 1
                        var p = Vector4(sourcePositions[i], 1)
                        var n = Vector4(sourceNormals.indices.contains(i) ? sourceNormals[i] : .zero, 0)
                        if !palette.isEmpty, let joints, let weights, i < joints.count, i < weights.count {
                            var skinnedP = Vector4.zero
                            var skinnedN = Vector4.zero
                            for component in 0..<4 {
                                let joint = Int(joints[i][component])
                                let weight = weights[i][component]
                                guard weight > 0, palette.indices.contains(joint) else { continue }
                                skinnedP += (palette[joint] * p) * weight
                                skinnedN += (palette[joint] * n) * weight
                            }
                            if skinnedP.w > 0.0001 {
                                p = skinnedP
                                n = skinnedN
                            }
                        }
                        return ((transform * p).xyz, (normalMatrix * n).xyz)
                    }
                    func uv(_ vertex: Int, _ slot: Int) -> Vector2 {
                        let coordinate = pbr.textureCoordinates.indices.contains(slot) ? pbr.textureCoordinates[slot] : 0
                        let buffer = coordinate == 1 ? uv1 : uv0
                        let value = buffer.indices.contains(vertex) ? buffer[vertex] : .zero
                        let t = pbr.textureTransforms.indices.contains(slot) ? pbr.textureTransforms[slot] : .identity
                        let x = value.x * t.scale.x
                        let y = value.y * t.scale.y
                        return Vector2(x * Math.cos(t.rotation) - y * Math.sin(t.rotation), x * Math.sin(t.rotation) + y * Math.cos(t.rotation)) + t.offset
                    }
                    for offset in stride(from: 0, to: min(part.indexCount, descriptor.indicies.count) - 2, by: 3) {
                        let ids = (0..<3).map { Int(descriptor.indicies[offset + $0]) }
                        guard ids.allSatisfy({ sourcePositions.indices.contains($0) }) else {
                            continue
                        }
                        let first = vertex(ids[0])
                        let second = vertex(ids[1])
                        let third = vertex(ids[2])
                        let a = first.position
                        let b = second.position
                        let c = third.position
                        guard LocalLighting3DMath.isFinite(a), LocalLighting3DMath.isFinite(b), LocalLighting3DMath.isFinite(c),
                            (b - a).cross(c - a).squaredLength > 1e-16
                        else {
                            continue
                        }
                        let flags = Float((source.castShadows ? 1 : 0) + (source.receiveShadows ? 2 : 0))
                        var vertices = [Vector4(a, Float(material)), Vector4(b, flags), Vector4(c, 0)]
                        vertices += [Vector4(first.normal, 0), Vector4(second.normal, 0), Vector4(third.normal, 0)]
                        vertices += ids.map {
                            let a = uv($0, 0)
                            let b = pbr.terrainBindings == nil ? uv($0, 1) : (uv1.indices.contains($0) ? uv1[$0] : .zero)
                            return Vector4(a.x, a.y, b.x, b.y)
                        }
                        vertices += ids.map {
                            let a = uv($0, 4)
                            let b = uv($0, 2)
                            return Vector4(a.x, a.y, b.x, b.y)
                        }
                        geometry.append(.init(vertices: vertices))
                    }
                }
            }
        }
        hardwareOrder = wantsHardwareOrder
        placements = placed
        parts = placedParts
        if wantsHardwareOrder {
            nodes = Self.dataTexture(instanceMetadata, label: "Path tracing instance materials and geometry offsets")
            triangles = hardwareGeometry.texture
            nodeCount = 0
        } else {
            hardwareGeometry = PathTracing3DGeometryTable()
            // Periodic rebuilding keeps the refitted hierarchy useful after large scene rearrangements.
            if generation % 120 == 0 { hierarchy = PathTracing3DBVH(geometry) } else { hierarchy.refit(geometry) }
            let bvh = hierarchy
            nodes = Self.dataTexture(bvh.packedNodes, label: "Path tracing BVH")
            triangles = Self.dataTexture(bvh.triangles.flatMap(\.vertices), label: "Path tracing triangles")
            nodeCount = bvh.nodes.count
        }
        terrainMaterials.appendHeaders(to: &materialData)
        materials = Self.dataTexture(materialData, label: "Path tracing materials")
        triangleCount = wantsHardwareOrder ? placedTriangleCount : geometry.count
        digest = full.value
        generation &+= 1
        if structureDigest != hash.value {
            structureDigest = hash.value
            structureGeneration &+= 1
        }
    }

    private mutating func prepareAtlas(
        _ textures: [PathTracingTextureInput],
        tileSize requestedTileSize: Int,
        device: RenderDevice
    ) async throws {
        let keys = textures.map(\.key)
        if keys != atlasKeys || atlas == nil || tileSize != requestedTileSize {
            tileSize = requestedTileSize
            let active = Set(
                textures.compactMap { input -> ObjectIdentifier? in
                    if case .material(let texture) = input {
                        return ObjectIdentifier(texture)
                    }
                    return nil
                }
            )
            images = images.filter { active.contains($0.key) }
            textureOwners = textureOwners.filter { active.contains($0.key) }
            for case .material(let texture) in textures where images[ObjectIdentifier(texture)] == nil {
                guard let image = try await device.readImage(from: texture), image.width > 0, image.height > 0 else {
                    throw PathTracing3DError.unsupported("Cannot read a material texture for the path tracing atlas")
                }
                images[ObjectIdentifier(texture)] = image
                textureOwners[ObjectIdentifier(texture)] = texture
            }
            let width = tileSize * Self.atlasColumns
            let rows = max(1, (textures.count + Self.atlasColumns - 1) / Self.atlasColumns)
            var pixels = [UInt8](repeating: 255, count: width * tileSize * rows * 4)
            for (index, input) in textures.enumerated() {
                let image: Image
                switch input {
                case .material(let texture):
                    guard let uploaded = images[ObjectIdentifier(texture)] else { continue }
                    image = uploaded
                case .terrain(_, _, _, let base):
                    image = base
                }
                for y in 0..<tileSize {
                    for x in 0..<tileSize {
                        let color = Self.pixel(image, x: min(image.width - 1, x * image.width / tileSize), y: min(image.height - 1, y * image.height / tileSize))
                        let start = ((index / Self.atlasColumns * tileSize + y) * width + index % Self.atlasColumns * tileSize + x) * 4
                        for channel in 0..<4 { pixels[start + channel] = UInt8(min(max(color[channel], 0), 1) * 255) }
                    }
                }
            }
            atlas = Texture2D(image: Image(width: width, height: rows * tileSize, data: Data(pixels)))
            atlasKeys = keys
        }
    }

    private mutating func prepareHardwareShading(
        _ preparedSources: [PreparedSource],
        uvLayouts: [RID: UInt64],
        hardwareTriangleStep: Int?
    ) throws {
        var keys: [PathTracing3DGeometryTable.Key] = []
        var seen: Set<PathTracing3DGeometryTable.Key> = []
        var missing: [(PathTracing3DGeometryTable.Key, Mesh.Part, PBRMaterial)] = []
        for prepared in preparedSources {
            for part in prepared.parts {
                let key = PathTracing3DGeometryTable.Key(part: .init(part), uvLayout: uvLayouts[prepared.source.materials[part.materialIndex].rid] ?? 0)
                if seen.insert(key).inserted {
                    keys.append(key)
                    if !hardwareGeometry.contains(key), let pbr = prepared.source.materials[part.materialIndex] as? PBRMaterial {
                        missing.append((key, part, pbr))
                    }
                }
            }
        }
        try hardwareGeometry.layout(keys, limit: Self.maximumHardwareTriangles)
        var packedTriangles = 0
        for (key, part, material) in missing {
            if let hardwareTriangleStep, packedTriangles > 0, key.count > hardwareTriangleStep - packedTriangles {
                throw PathTracing3DError.preparingGeometry
            }
            preparedVertexCount += hardwareGeometry.pack(part, material: material, key: key)
            packedTriangles += key.count
        }
        guard hardwareGeometry.upload(maximumWords: hardwareTriangleStep.map { $0 * 12 }) else {
            throw PathTracing3DError.preparingGeometry
        }
    }

    private static func validateHardwareInstanceBudget(_ sources: [PreparedSource]) throws {
        var remaining = Self.maximumHardwareInstances
        for prepared in sources {
            let count = prepared.source.instances?.count ?? 1
            guard count <= remaining / prepared.parts.count else {
                throw PathTracing3DError.unsupported("Path tracing hardware instance budget exceeded")
            }
            remaining -= count * prepared.parts.count
        }
    }

    // Count eligible input work, including degenerate triangles, before allocating expanded geometry.
    // Only referenced vertices are transformed below: large unused POSITION accessors cannot
    // multiply vertex work by the placement count.
    private static func validateWorkBudget(_ sources: [PreparedSource]) throws {
        var remainingPlacements = maximumTriangles
        var remainingTriangles = maximumTriangles
        for prepared in sources {
            let placements = prepared.source.instances?.count ?? 1
            guard placements <= remainingPlacements else {
                throw PathTracing3DError.unsupported("Path tracing placement budget exceeded (131072)")
            }
            remainingPlacements -= placements
            guard placements > 0 else { continue }
            for part in prepared.parts {
                let triangles = min(part.indexCount, part.meshDescriptor.indicies.count) / 3
                guard triangles <= remainingTriangles / placements else {
                    throw PathTracing3DError.unsupported("Path tracing triangle work budget exceeded (131072)")
                }
                remainingTriangles -= triangles * placements
            }
        }
    }

    static func dataTexture(_ values: [Vector4], label: String) -> Texture2D {
        let rows = max(1, (values.count + dataWidth - 1) / dataWidth)
        var data = values
        data.append(contentsOf: repeatElement(.zero, count: dataWidth * rows - data.count))
        let texture = Texture2D(
            descriptor: .init(width: dataWidth, height: rows, pixelFormat: .rgba_32f, textureUsage: [.read], textureType: .texture2D, debugLabel: label)
        )
        unsafe data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                unsafe texture.replaceRegion(.init(x: 0, y: 0, width: dataWidth, height: rows), withBytes: base, bytesPerRow: dataWidth * 16)
            }
        }
        return texture
    }

    private static func pixel(_ image: Image, x: Int, y: Int) -> Vector4 {
        let channels = image.format == .rgb8 ? 3 : (image.format == .gray ? 1 : 4)
        let i = (y * image.width + x) * channels
        guard i + channels <= image.data.count else {
            return .one
        }
        let a = Float(image.data[i]) / 255
        if channels == 1 {
            return [a, a, a, 1]
        }
        let b = Float(image.data[i + 1]) / 255
        let c = Float(image.data[i + 2]) / 255
        let alpha = channels == 4 ? Float(image.data[i + 3]) / 255 : 1
        return image.format == .bgra8 || image.format == .bgra8_sRGB ? [c, b, a, alpha] : [a, b, c, alpha]
    }
}
