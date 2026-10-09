//
//  NativeGLTFLoader.swift
//  AdaEngine
//
//  Created by v.prusakov on 05/30/24.
//

import Foundation
import Math

public struct NativeGLTFLoader: GLTFLoader {
    public init() {}

    public func load(url: URL) async throws -> GLTFImportResult {
        let data = try Data(contentsOf: url)
        return try load(data: data, baseURL: url.deletingLastPathComponent())
    }

    /// Loads a glTF or GLB document from memory.
    public func load(data: Data, baseURL: URL? = nil) throws -> GLTFImportResult {
        let resourceBaseURL = baseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let gltf: GLTF
        let binaryBuffer: Data?

        if data.prefix(4) == Data("glTF".utf8) {
            let (parsedGltf, parsedBinaryBuffer) = try parseGLB(data)
            gltf = parsedGltf
            binaryBuffer = parsedBinaryBuffer
        } else {
            gltf = try JSONDecoder().decode(GLTF.self, from: data)
            binaryBuffer = nil
        }

        let supportedExtensions: Set<String> = ["KHR_mesh_quantization", "KHR_materials_emissive_strength"]
        if let unsupportedExtension = gltf.extensionsRequired?.first(where: { !supportedExtensions.contains($0) }) {
            throw GLTFError.unsupportedRequiredExtension(unsupportedExtension)
        }

        let buffers = try loadBuffers(gltf.buffers ?? [], baseURL: resourceBaseURL, binaryBuffer: binaryBuffer)

        return try convertToImportResult(gltf, buffers: buffers, baseURL: resourceBaseURL)
    }

    private func parseGLB(_ data: Data) throws -> (GLTF, Data?) {
        guard data.count >= 12 else {
            throw GLTFError.invalidGLB
        }
        let magic = data.subdata(in: 0 ..< 4)
        let version = readUInt32(data, at: 4)
        let declaredLength = Int(readUInt32(data, at: 8))

        if magic != Data("glTF".utf8) || version != 2 || declaredLength != data.count {
            throw GLTFError.invalidGLB
        }

        var offset = 12
        var gltf: GLTF?
        var binaryBuffer: Data?

        while offset < data.count {
            guard offset + 8 <= data.count else {
                throw GLTFError.invalidGLB
            }
            let chunkLength = Int(readUInt32(data, at: offset))
            let chunkType = readUInt32(data, at: offset + 4)
            guard offset + 8 + chunkLength <= data.count else {
                throw GLTFError.invalidGLB
            }
            let chunkData = data.subdata(in: offset + 8 ..< offset + 8 + chunkLength)

            if chunkType == 0x4E4F_534A { // JSON
                gltf = try JSONDecoder().decode(GLTF.self, from: chunkData)
            } else if chunkType == 0x004E_4942 { // BIN
                binaryBuffer = chunkData
            }

            offset += 8 + chunkLength
        }

        guard let resultGltf = gltf else {
            throw GLTFError.missingJSONChunk
        }

        return (resultGltf, binaryBuffer)
    }

    private func loadBuffers(_ gltfBuffers: [GLTF.Buffer], baseURL: URL, binaryBuffer: Data?) throws -> [Data] {
        var buffers = [Data]()

        for (index, buffer) in gltfBuffers.enumerated() {
            if index == 0, let binaryBuffer {
                guard binaryBuffer.count >= buffer.byteLength else {
                    throw GLTFError.bufferTooShort
                }
                buffers.append(binaryBuffer)
                continue
            }

            guard let uri = buffer.uri else {
                throw GLTFError.missingBufferURI
            }

            if uri.starts(with: "data:") {
                try buffers.append(decodeDataURI(uri))
            } else {
                let bufferURL = try resourceURL(uri, relativeTo: baseURL)
                let data = try Data(contentsOf: bufferURL)
                buffers.append(data)
            }

            guard buffers.last?.count ?? 0 >= buffer.byteLength else {
                throw GLTFError.bufferTooShort
            }
        }

        return buffers
    }

    private func convertToImportResult(_ gltf: GLTF, buffers: [Data], baseURL: URL) throws -> GLTFImportResult {
        let images = try (gltf.images ?? [])
            .map { image -> GLTFImportResult.Image in
                if let uri = image.uri {
                    if uri.starts(with: "data:") {
                        return try GLTFImportResult.Image(uri: nil, data: decodeDataURI(uri), mimeType: image.mimeType)
                    }
                    let imageURL = try resourceURL(uri, relativeTo: baseURL)
                    return try GLTFImportResult.Image(uri: imageURL, data: Data(contentsOf: imageURL), mimeType: image.mimeType)
                } else if let bufferViewIndex = image.bufferView {
                    let data = try getBufferViewData(bufferViewIndex, gltf: gltf, buffers: buffers)
                    return GLTFImportResult.Image(uri: nil, data: data, mimeType: image.mimeType)
                }
                return GLTFImportResult.Image(uri: nil, data: nil, mimeType: image.mimeType)
            }

        let samplers = try importSamplers(gltf)
        let textures = try (gltf.textures ?? []).enumerated().map { index, texture in
            guard let source = texture.source, images.indices.contains(source),
                  texture.sampler.map({ samplers.indices.contains($0) }) ?? true
            else { throw GLTFError.invalidTexture(index) }
            return GLTFImportResult.Texture(source: source, sampler: texture.sampler)
        }
        let materials = try importMaterials(gltf)

        let meshes = try (gltf.meshes ?? [])
            .map { mesh -> GLTFImportResult.Mesh in
                let primitives = try mesh.primitives.map { primitive -> GLTFImportResult.Primitive in
                    var attributes = [GLTFImportResult.Attribute: GLTFImportResult.Accessor]()

                    for (key, accessorIndex) in primitive.attributes {
                        let attribute = try mapAttribute(key)
                        let decoded = try decodeAccessor(accessorIndex, gltf: gltf, buffers: buffers)
                        attributes[attribute] = GLTFImportResult.Accessor(
                            values: decoded.values.map(Float.init),
                            componentCount: decoded.componentCount
                        )
                    }

                    let indices: [UInt32]?
                    if let indicesIndex = primitive.indices {
                        let decoded = try decodeAccessor(indicesIndex, gltf: gltf, buffers: buffers)
                        guard decoded.componentCount == 1 else {
                            throw GLTFError.invalidIndices
                        }
                        indices = try decoded.values.map { value in
                            guard value >= 0, value <= Double(UInt32.max), value.rounded() == value else {
                                throw GLTFError.invalidIndices
                            }
                            return UInt32(value)
                        }
                    } else {
                        indices = nil
                    }

                    return try GLTFImportResult.Primitive(
                        attributes: attributes,
                        indices: indices,
                        materialIndex: primitive.material,
                        mode: GLTFImportResult.PrimitiveMode(rawValue: primitive.mode ?? 4) ?? .triangles,
                        skinning: importSkinning(primitive, attributes: attributes, gltf: gltf)
                    )
                }

                return GLTFImportResult.Mesh(name: mesh.name, primitives: primitives)
            }

        let nodes = try importNodes(gltf)
        let skins = try importSkins(gltf, buffers: buffers)
        try validateSkinBindings(nodes: nodes, meshes: meshes, skins: skins)
        let animations = try importAnimations(gltf, buffers: buffers)

        let scenes = (gltf.scenes ?? []).map { $0.nodes ?? [] }

        return GLTFImportResult(
            nodes: nodes,
            meshes: meshes,
            materials: materials,
            textures: textures,
            images: images,
            scenes: scenes,
            defaultScene: gltf.scene,
            skins: skins,
            animations: animations,
            samplers: samplers
        )
    }

    private func mapAttribute(_ key: String) throws -> GLTFImportResult.Attribute {
        switch key {
        case "POSITION": return .position
        case "NORMAL": return .normal
        case "TANGENT": return .tangent
        case let str where str.starts(with: "TEXCOORD_"):
            let index = Int(str.dropFirst("TEXCOORD_".count)) ?? 0
            return .texCoord(index)
        case let str where str.starts(with: "COLOR_"):
            let index = Int(str.dropFirst("COLOR_".count)) ?? 0
            return .color(index)
        case let str where str.starts(with: "JOINTS_"):
            guard let index = Int(str.dropFirst("JOINTS_".count)), index >= 0 else {
                throw GLTFError.unknownAttribute(key)
            }
            return .joints(index)
        case let str where str.starts(with: "WEIGHTS_"):
            guard let index = Int(str.dropFirst("WEIGHTS_".count)), index >= 0 else {
                throw GLTFError.unknownAttribute(key)
            }
            return .weights(index)
        case let str where str.starts(with: "_"):
            return .custom(str)
        default:
            throw GLTFError.unknownAttribute(key)
        }
    }

    func getBufferViewData(_ index: Int, gltf: GLTF, buffers: [Data]) throws -> Data {
        guard let bufferViews = gltf.bufferViews, bufferViews.indices.contains(index) else {
            throw GLTFError.invalidBufferViewIndex(index)
        }
        let bufferView = bufferViews[index]
        guard buffers.indices.contains(bufferView.buffer) else {
            throw GLTFError.invalidBufferIndex(bufferView.buffer)
        }
        let offset = bufferView.byteOffset ?? 0
        let buffer = buffers[bufferView.buffer]
        guard offset >= 0, bufferView.byteLength >= 0, offset + bufferView.byteLength <= buffer.count else {
            throw GLTFError.bufferOutOfBounds
        }
        return buffer.subdata(in: offset ..< offset + bufferView.byteLength)
    }

    private func resourceURL(_ uri: String, relativeTo base: URL) throws -> URL {
        let decoded = uri.removingPercentEncoding ?? uri
        let target = base.appendingPathComponent(decoded).standardizedFileURL
        if let root = AssetsManager.restrictedResourceRoot {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\"),
                  !decoded.contains("?"), !decoded.contains("#"), canonicalTarget.hasPrefix(canonicalRoot + "/") else {
                throw GLTFError.invalidDataURI
            }
        }
        return target
    }

    private func decodeDataURI(_ uri: String) throws -> Data {
        guard uri.starts(with: "data:"), let commaIndex = uri.firstIndex(of: ",") else {
            throw GLTFError.invalidDataURI
        }
        let metadata = uri[..<commaIndex]
        let payload = String(uri[uri.index(after: commaIndex)...])
        if metadata.hasSuffix(";base64") {
            guard let data = Data(base64Encoded: payload) else {
                throw GLTFError.invalidDataURI
            }
            return data
        }
        guard let decoded = payload.removingPercentEncoding else {
            throw GLTFError.invalidDataURI
        }
        return Data(decoded.utf8)
    }
}
