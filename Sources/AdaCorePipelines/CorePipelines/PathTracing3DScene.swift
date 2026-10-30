import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math

enum PathTracing3DError: Error, CustomStringConvertible {
    case unsupported(String)
    var description: String { switch self { case .unsupported(let reason): reason } }
}

/// CPU geometry is never camera culled. A light and its occluder can both be behind the camera.
struct PathTracing3DScene: Sendable {
    /// Non-shadow-casting graph cards/domes are cosmetic layers, composited after surface transport.
    static func isRasterOverlay(_ material: Material, castsShadows: Bool) -> Bool {
        !castsShadows && (material as? PBRMaterial)?.graphMaterial != nil
    }
    static let dataWidth = 2048
    static let tileSize = 128
    static let atlasColumns = 16
    static let maximumTextures = 256
    static let maximumTriangles = 131072
    var nodes: Texture2D?
    var triangles: Texture2D?
    var materials: Texture2D?
    var atlas: Texture2D?
    var nodeCount = 0
    var triangleCount = 0
    var digest: UInt64?
    var generation: UInt64 = 0
    private var images: [ObjectIdentifier: Image] = [:]
    private var textureOwners: [ObjectIdentifier: Texture2D] = [:]
    private var atlasKeys: [ObjectIdentifier] = []
    private var hierarchy = PathTracing3DBVH([])

    mutating func prepare(_ sources: [Mesh3DRenderSource], skinning: Skinning3DUniforms?, device: RenderDevice) async throws {
        let sources = sources.filter { source in
            !source.materials.allSatisfy { Self.isRasterOverlay($0, castsShadows: source.castShadows) }
        }
        var hash = FrameDigest3D()
        var materialList: [PBRMaterial] = []
        var materialIDs: [RID: Int] = [:]
        var textures: [Texture2D] = []
        var textureIDs: [ObjectIdentifier: Int] = [:]
        for source in sources {
            guard source.morphBuffers.isEmpty else {
                throw PathTracing3DError.unsupported("Mesh morph targets are not supported by portable path tracing")
            }
            if source.skinningBuffer != nil && (skinning?.matrices(for: source.entity).isEmpty ?? true) {
                throw PathTracing3DError.unsupported("The current skinning palette is unavailable for path tracing")
            }
            hash.combine(UInt64(source.entity)); hash.combine(source.transform)
            hash.combine(source.castShadows ? UInt64(1) : 0); hash.combine(source.receiveShadows ? UInt64(1) : 0)
            for matrix in skinning?.matrices(for: source.entity) ?? [] { hash.combine(matrix) }
            for model in source.mesh.models { for part in model.parts {
                hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.vertexBuffer).hashValue)))
                hash.combine(UInt64(bitPattern: Int64(ObjectIdentifier(part.indexBuffer).hashValue)))
                hash.combine(UInt64(part.indexCount))
            } }
            for material in source.materials {
                if Self.isRasterOverlay(material, castsShadows: source.castShadows) { continue }
                guard let pbr = material as? PBRMaterial, pbr.graphMaterial == nil else {
                    throw PathTracing3DError.unsupported("Unsupported traced material \(String(reflecting:type(of:material))) on entity \(source.entity); shadow-casting shader graphs require a tracing material")
                }
                if materialIDs[pbr.rid] == nil { materialIDs[pbr.rid] = materialList.count; materialList.append(pbr) }
                hash.combine(pbr.baseColorFactor); hash.combine(Vector4(pbr.emissiveFactor, pbr.emissiveStrength))
                hash.combine(Vector4(pbr.metallicFactor, pbr.roughnessFactor, pbr.effectiveAlphaCutoff, pbr.normalScale))
                hash.combine(UInt64(pbr.effectiveAlphaMode.rawValue)); hash.combine(pbr.effectiveDoubleSided ? UInt64(1) : 0)
                for transform in pbr.textureTransforms {
                    hash.combine(Vector4(transform.offset.x, transform.offset.y, transform.scale.x, transform.scale.y)); hash.combine(transform.rotation)
                }
                for coordinate in pbr.textureCoordinates { hash.combine(UInt64(max(0, coordinate))) }
                for texture in [pbr.baseColorTexture, pbr.metallicRoughnessTexture, pbr.emissiveTexture, pbr.normalTexture] {
                    guard let texture else { hash.combine(UInt64(0)); continue }
                    let key = ObjectIdentifier(texture)
                    hash.combine(UInt64(bitPattern: Int64(key.hashValue)))
                    if textureIDs[key] == nil { textureIDs[key] = textures.count; textures.append(texture) }
                }
            }
        }
        if digest == hash.value { return }
        guard textures.count <= Self.maximumTextures else { throw PathTracing3DError.unsupported("Path tracing texture budget exceeded (256)") }
        let keys = textures.map(ObjectIdentifier.init)
        if keys != atlasKeys || atlas == nil {
            let active = Set(keys)
            images = images.filter { active.contains($0.key) }; textureOwners = textureOwners.filter { active.contains($0.key) }
            for texture in textures where images[ObjectIdentifier(texture)] == nil {
                guard let image = try await device.readImage(from: texture), image.width > 0, image.height > 0 else {
                    throw PathTracing3DError.unsupported("Cannot read a material texture for the path tracing atlas")
                }
                images[ObjectIdentifier(texture)] = image; textureOwners[ObjectIdentifier(texture)] = texture
            }
            let width = Self.tileSize*Self.atlasColumns
            let rows = max(1, (textures.count+Self.atlasColumns-1)/Self.atlasColumns)
            var pixels = [UInt8](repeating: 255, count: width*Self.tileSize*rows*4)
            for (index, texture) in textures.enumerated() {
                guard let image = images[ObjectIdentifier(texture)] else { continue }
                for y in 0..<Self.tileSize { for x in 0..<Self.tileSize {
                    let color = Self.pixel(image, x: min(image.width-1,x*image.width/Self.tileSize), y: min(image.height-1,y*image.height/Self.tileSize))
                    let start = ((index/Self.atlasColumns*Self.tileSize+y)*width+index%Self.atlasColumns*Self.tileSize+x)*4
                    for channel in 0..<4 { pixels[start+channel] = UInt8(min(max(color[channel], 0), 1)*255) }
                } }
            }
            atlas = Texture2D(image: Image(width: width, height: rows*Self.tileSize, data: Data(pixels)))
            atlasKeys = keys
        }
        func tile(_ texture: Texture2D?) -> Float { texture.flatMap { textureIDs[ObjectIdentifier($0)] }.map(Float.init) ?? -1 }
        var materialData: [Vector4] = []
        for pbr in materialList {
            materialData += [pbr.baseColorFactor, Vector4(pbr.emissiveFactor*pbr.emissiveStrength, 0),
                Vector4(pbr.metallicFactor,pbr.roughnessFactor,pbr.effectiveAlphaCutoff,pbr.effectiveDoubleSided ? 1 : 0),
                Vector4(tile(pbr.baseColorTexture),tile(pbr.metallicRoughnessTexture),tile(pbr.emissiveTexture),tile(pbr.normalTexture)),
                Vector4(Float(pbr.effectiveAlphaMode.rawValue),pbr.normalScale,0,0)]
        }
        var geometry: [PathTracing3DBVH.Triangle] = []
        for source in sources {
            let palette = skinning?.matrices(for: source.entity) ?? []
            let normalMatrix = source.transform.inverse.transpose
            for model in source.mesh.models { for part in model.parts {
                guard part.primitiveTopology == .triangleList, source.materials.indices.contains(part.materialIndex),
                    let pbr = source.materials[part.materialIndex] as? PBRMaterial, let material = materialIDs[pbr.rid] else { continue }
                let descriptor = part.meshDescriptor
                let sourcePositions = descriptor.positions.elements, sourceNormals = descriptor.normals?.elements ?? []
                let joints = descriptor[MeshDescriptor.jointIndices]?.elements, weights = descriptor[MeshDescriptor.jointWeights]?.elements
                let uv0 = descriptor.textureCoordinates?.elements ?? [], uv1 = descriptor[MeshDescriptor.textureCoordinates1]?.elements ?? []
                var positions: [Vector3] = [], normals: [Vector3] = []
                for i in sourcePositions.indices {
                    var p = Vector4(sourcePositions[i],1), n = Vector4(sourceNormals.indices.contains(i) ? sourceNormals[i] : .zero,0)
                    if !palette.isEmpty, let joints, let weights, i < joints.count, i < weights.count {
                        var skinnedP = Vector4.zero, skinnedN = Vector4.zero
                        for component in 0..<4 {
                            let joint = Int(joints[i][component]), weight = weights[i][component]
                            guard weight > 0, palette.indices.contains(joint) else { continue }
                            skinnedP += (palette[joint]*p)*weight; skinnedN += (palette[joint]*n)*weight
                        }
                        if skinnedP.w > 0.0001 { p = skinnedP; n = skinnedN }
                    }
                    positions.append((source.transform*p).xyz); normals.append((normalMatrix*n).xyz)
                }
                func uv(_ vertex: Int, _ slot: Int) -> Vector2 {
                    let coordinate = pbr.textureCoordinates.indices.contains(slot) ? pbr.textureCoordinates[slot] : 0
                    let buffer = coordinate == 1 ? uv1 : uv0
                    let value = buffer.indices.contains(vertex) ? buffer[vertex] : .zero
                    let t = pbr.textureTransforms.indices.contains(slot) ? pbr.textureTransforms[slot] : .identity
                    let x = value.x*t.scale.x, y = value.y*t.scale.y
                    return Vector2(x*Math.cos(t.rotation)-y*Math.sin(t.rotation),x*Math.sin(t.rotation)+y*Math.cos(t.rotation))+t.offset
                }
                for offset in stride(from: 0, to: min(part.indexCount,descriptor.indicies.count)-2, by: 3) {
                    let ids = (0..<3).map { Int(descriptor.indicies[offset+$0]) }
                    guard ids.allSatisfy({ positions.indices.contains($0) }) else { continue }
                    let a = positions[ids[0]], b = positions[ids[1]], c = positions[ids[2]]
                    guard LocalLighting3DMath.isFinite(a), LocalLighting3DMath.isFinite(b), LocalLighting3DMath.isFinite(c),
                        (b-a).cross(c-a).squaredLength > 1e-16 else { continue }
                    let flags = Float((source.castShadows ? 1 : 0)+(source.receiveShadows ? 2 : 0))
                    var vertices = [Vector4(a,Float(material)),Vector4(b,flags),Vector4(c,0)]
                    vertices += ids.map { Vector4(normals[$0],0) }
                    vertices += ids.map { let a = uv($0,0), b = uv($0,1); return Vector4(a.x,a.y,b.x,b.y) }
                    vertices += ids.map { let a = uv($0,4), b = uv($0,2); return Vector4(a.x,a.y,b.x,b.y) }
                    geometry.append(.init(vertices:vertices))
                    guard geometry.count <= Self.maximumTriangles else { throw PathTracing3DError.unsupported("Path tracing triangle budget exceeded (131072)") }
                }
            } }
        }
        // Periodic rebuilding keeps the refitted hierarchy useful after large scene rearrangements.
        if generation % 120 == 0 { hierarchy = PathTracing3DBVH(geometry) }
        else { hierarchy.refit(geometry) }
        let bvh = hierarchy
        nodes = Self.dataTexture(bvh.packedNodes, label: "Path tracing BVH")
        triangles = Self.dataTexture(bvh.triangles.flatMap(\.vertices), label: "Path tracing triangles")
        materials = Self.dataTexture(materialData, label: "Path tracing materials")
        nodeCount = bvh.nodes.count; triangleCount = geometry.count
        digest = hash.value; generation &+= 1
    }

    static func dataTexture(_ values: [Vector4], label: String) -> Texture2D {
        let rows = max(1,(values.count+dataWidth-1)/dataWidth)
        var data = values
        data.append(contentsOf: repeatElement(.zero,count:dataWidth*rows-data.count))
        let texture = Texture2D(descriptor: .init(width:dataWidth,height:rows,pixelFormat:.rgba_32f,textureUsage:[.read],textureType:.texture2D,debugLabel:label))
        unsafe data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { unsafe texture.replaceRegion(.init(x:0,y:0,width:dataWidth,height:rows),withBytes:base,bytesPerRow:dataWidth*16) }
        }
        return texture
    }

    private static func pixel(_ image: Image, x: Int, y: Int) -> Vector4 {
        let channels = image.format == .rgb8 ? 3 : (image.format == .gray ? 1 : 4)
        let i = (y*image.width+x)*channels
        guard i+channels <= image.data.count else { return .one }
        let a = Float(image.data[i])/255
        if channels == 1 { return [a,a,a,1] }
        let b = Float(image.data[i+1])/255, c = Float(image.data[i+2])/255
        let alpha = channels == 4 ? Float(image.data[i+3])/255 : 1
        return image.format == .bgra8 || image.format == .bgra8_sRGB ? [c,b,a,alpha] : [a,b,c,alpha]
    }
}
