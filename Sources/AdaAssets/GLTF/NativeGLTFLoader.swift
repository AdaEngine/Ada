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

        let supportedExtensions: Set<String> = ["KHR_mesh_quantization"]
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
        let magic = data.subdata(in: 0..<4)
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
            let chunkData = data.subdata(in: offset + 8..<offset + 8 + chunkLength)

            if chunkType == 0x4E4F_534A {  // JSON
                gltf = try JSONDecoder().decode(GLTF.self, from: chunkData)
            } else if chunkType == 0x004E_4942 {  // BIN
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
                buffers.append(try decodeDataURI(uri))
            } else {
                let bufferURL = baseURL.appendingPathComponent(uri.removingPercentEncoding ?? uri)
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
                        return GLTFImportResult.Image(uri: nil, data: try decodeDataURI(uri), mimeType: image.mimeType)
                    }
                    let imageURL = baseURL.appendingPathComponent(uri.removingPercentEncoding ?? uri)
                    return GLTFImportResult.Image(uri: imageURL, data: try Data(contentsOf: imageURL), mimeType: image.mimeType)
                } else if let bufferViewIndex = image.bufferView {
                    let data = try getBufferViewData(bufferViewIndex, gltf: gltf, buffers: buffers)
                    return GLTFImportResult.Image(uri: nil, data: data, mimeType: image.mimeType)
                }
                return GLTFImportResult.Image(uri: nil, data: nil, mimeType: image.mimeType)
            }

        let textures = (gltf.textures ?? [])
            .map { texture in
                GLTFImportResult.Texture(source: texture.source ?? 0, sampler: texture.sampler)
            }

        let materials = (gltf.materials ?? [])
            .map { material -> GLTFImportResult.Material in
                let pbr = material.pbrMetallicRoughness
                let baseColorFactor = pbr?.baseColorFactor ?? [1, 1, 1, 1]
                let baseColor = Vector4(x: baseColorFactor[0], y: baseColorFactor[1], z: baseColorFactor[2], w: baseColorFactor[3])

                return GLTFImportResult.Material(
                    name: material.name,
                    baseColorFactor: baseColor,
                    baseColorTextureIndex: pbr?.baseColorTexture?.index,
                    metallicFactor: pbr?.metallicFactor ?? 1.0,
                    roughnessFactor: pbr?.roughnessFactor ?? 1.0,
                    metallicRoughnessTextureIndex: pbr?.metallicRoughnessTexture?.index,
                    normalTextureIndex: material.normalTexture?.index
                )
            }

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

                    return GLTFImportResult.Primitive(
                        attributes: attributes,
                        indices: indices,
                        materialIndex: primitive.material,
                        mode: GLTFImportResult.PrimitiveMode(rawValue: primitive.mode ?? 4) ?? .triangles
                    )
                }

                return GLTFImportResult.Mesh(name: mesh.name, primitives: primitives)
            }

        let nodes = (gltf.nodes ?? [])
            .map { node -> GLTFImportResult.Node in
                let transform: Transform3D

                if let matrix = node.matrix {
                    // glTF uses column-major matrices
                    transform = Transform3D(
                        Vector4(x: matrix[0], y: matrix[1], z: matrix[2], w: matrix[3]),
                        Vector4(x: matrix[4], y: matrix[5], z: matrix[6], w: matrix[7]),
                        Vector4(x: matrix[8], y: matrix[9], z: matrix[10], w: matrix[11]),
                        Vector4(x: matrix[12], y: matrix[13], z: matrix[14], w: matrix[15])
                    )
                } else {
                    let translation = node.translation ?? [0, 0, 0]
                    let rotation = node.rotation ?? [0, 0, 0, 1]
                    let scale = node.scale ?? [1, 1, 1]

                    let t = Transform3D(translation: Vector3(x: translation[0], y: translation[1], z: translation[2]))
                    let r = Transform3D(quat: Quat(x: rotation[0], y: rotation[1], z: rotation[2], w: rotation[3]))
                    let s = Transform3D(scale: Vector3(x: scale[0], y: scale[1], z: scale[2]))

                    transform = t * r * s
                }

                return GLTFImportResult.Node(
                    name: node.name,
                    transform: transform,
                    children: node.children ?? [],
                    meshIndex: node.mesh
                )
            }

        let scenes = (gltf.scenes ?? []).map { $0.nodes ?? [] }

        return GLTFImportResult(
            nodes: nodes,
            meshes: meshes,
            materials: materials,
            textures: textures,
            images: images,
            scenes: scenes,
            defaultScene: gltf.scene
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
            let index = Int(str.dropFirst("JOINTS_".count)) ?? 0
            return .joints(index)
        case let str where str.starts(with: "WEIGHTS_"):
            let index = Int(str.dropFirst("WEIGHTS_".count)) ?? 0
            return .weights(index)
        case let str where str.starts(with: "_"):
            return .custom(str)
        default:
            throw GLTFError.unknownAttribute(key)
        }
    }

    private func decodeAccessor(_ accessorIndex: Int, gltf: GLTF, buffers: [Data]) throws -> DecodedAccessor {
        guard let accessors = gltf.accessors, accessors.indices.contains(accessorIndex) else {
            throw GLTFError.invalidAccessorIndex(accessorIndex)
        }
        let accessor = accessors[accessorIndex]
        let componentSize = try componentSize(for: accessor.componentType)
        let componentCount = try componentCount(for: accessor.type)
        var values = [Double](repeating: 0, count: accessor.count * componentCount)

        if let bufferViewIndex = accessor.bufferView {
            guard let bufferViews = gltf.bufferViews, bufferViews.indices.contains(bufferViewIndex) else {
                throw GLTFError.invalidBufferViewIndex(bufferViewIndex)
            }
            let bufferView = bufferViews[bufferViewIndex]
            guard buffers.indices.contains(bufferView.buffer) else {
                throw GLTFError.invalidBufferIndex(bufferView.buffer)
            }
            let elementSize = componentSize * componentCount
            let byteStride = bufferView.byteStride ?? elementSize
            guard byteStride >= elementSize else {
                throw GLTFError.invalidStride
            }
            let bufferViewOffset = bufferView.byteOffset ?? 0
            let bufferViewEnd = bufferViewOffset + bufferView.byteLength
            let startOffset = bufferViewOffset + (accessor.byteOffset ?? 0)
            let buffer = buffers[bufferView.buffer]

            for elementIndex in 0..<accessor.count {
                let elementOffset = startOffset + elementIndex * byteStride
                guard
                    elementOffset >= bufferViewOffset,
                    elementOffset + elementSize <= bufferViewEnd,
                    elementOffset + elementSize <= buffer.count
                else {
                    throw GLTFError.bufferOutOfBounds
                }
                for componentIndex in 0..<componentCount {
                    values[elementIndex * componentCount + componentIndex] = try readComponent(
                        buffer,
                        at: elementOffset + componentIndex * componentSize,
                        componentType: accessor.componentType,
                        normalized: accessor.normalized ?? false
                    )
                }
            }
        }

        if let sparse = accessor.sparse {
            let sparseIndices = try decodeSparseIndices(sparse.indices, count: sparse.count, gltf: gltf, buffers: buffers)
            let sparseValues = try decodeSparseValues(
                sparse.values,
                count: sparse.count,
                componentType: accessor.componentType,
                componentCount: componentCount,
                normalized: accessor.normalized ?? false,
                gltf: gltf,
                buffers: buffers
            )
            for sparseIndex in 0..<sparse.count {
                let destinationIndex = sparseIndices[sparseIndex]
                guard destinationIndex < accessor.count else {
                    throw GLTFError.sparseIndexOutOfBounds
                }
                for componentIndex in 0..<componentCount {
                    values[destinationIndex * componentCount + componentIndex] = sparseValues[sparseIndex * componentCount + componentIndex]
                }
            }
        }

        return DecodedAccessor(values: values, componentCount: componentCount)
    }

    private func decodeSparseIndices(
        _ indices: GLTF.Accessor.Sparse.Indices,
        count: Int,
        gltf: GLTF,
        buffers: [Data]
    ) throws -> [Int] {
        guard [5121, 5123, 5125].contains(indices.componentType) else {
            throw GLTFError.invalidComponentType(indices.componentType)
        }
        let data = try getBufferViewData(indices.bufferView, gltf: gltf, buffers: buffers)
        let size = try componentSize(for: indices.componentType)
        let offset = indices.byteOffset ?? 0
        guard offset >= 0, offset + count * size <= data.count else {
            throw GLTFError.bufferOutOfBounds
        }
        return try (0..<count)
            .map {
                Int(try readComponent(data, at: offset + $0 * size, componentType: indices.componentType, normalized: false))
            }
    }

    private func decodeSparseValues(
        _ sparseValues: GLTF.Accessor.Sparse.Values,
        count: Int,
        componentType: Int,
        componentCount: Int,
        normalized: Bool,
        gltf: GLTF,
        buffers: [Data]
    ) throws -> [Double] {
        let data = try getBufferViewData(sparseValues.bufferView, gltf: gltf, buffers: buffers)
        let size = try componentSize(for: componentType)
        let offset = sparseValues.byteOffset ?? 0
        let valueCount = count * componentCount
        guard offset >= 0, offset + valueCount * size <= data.count else {
            throw GLTFError.bufferOutOfBounds
        }
        return try (0..<valueCount)
            .map {
                try readComponent(data, at: offset + $0 * size, componentType: componentType, normalized: normalized)
            }
    }

    private func getBufferViewData(_ index: Int, gltf: GLTF, buffers: [Data]) throws -> Data {
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
        return buffer.subdata(in: offset..<offset + bufferView.byteLength)
    }

    private func componentSize(for componentType: Int) throws -> Int {
        switch componentType {
        case 5120,
            5121:
            return 1
        case 5122,
            5123:
            return 2
        case 5125,
            5126:
            return 4
        default: throw GLTFError.invalidComponentType(componentType)
        }
    }

    private func componentCount(for accessorType: String) throws -> Int {
        switch accessorType {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4",
            "MAT2":
            return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: throw GLTFError.invalidAccessorType(accessorType)
        }
    }

    private func readComponent(_ data: Data, at offset: Int, componentType: Int, normalized: Bool) throws -> Double {
        let rawValue: Double
        switch componentType {
        case 5120:
            rawValue = Double(Int8(bitPattern: data[offset]))
        case 5121:
            rawValue = Double(data[offset])
        case 5122:
            rawValue = Double(Int16(bitPattern: readUInt16(data, at: offset)))
        case 5123:
            rawValue = Double(readUInt16(data, at: offset))
        case 5125:
            rawValue = Double(readUInt32(data, at: offset))
        case 5126:
            rawValue = Double(Float(bitPattern: readUInt32(data, at: offset)))
        default:
            throw GLTFError.invalidComponentType(componentType)
        }

        guard normalized else {
            return rawValue
        }
        switch componentType {
        case 5120: return max(rawValue / 127, -1)
        case 5121: return rawValue / 255
        case 5122: return max(rawValue / 32767, -1)
        case 5123: return rawValue / 65535
        default: return rawValue
        }
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

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private struct DecodedAccessor {
        let values: [Double]
        let componentCount: Int
    }

    // MARK: - Internal GLTF Schema

    private enum GLTFError: Error {
        case invalidGLB
        case missingJSONChunk
        case missingBufferURI
        case invalidDataURI
        case bufferTooShort
        case bufferOutOfBounds
        case invalidStride
        case invalidIndices
        case sparseIndexOutOfBounds
        case invalidAccessorIndex(Int)
        case invalidBufferViewIndex(Int)
        case invalidBufferIndex(Int)
        case unknownAttribute(String)
        case invalidComponentType(Int)
        case invalidAccessorType(String)
        case unsupportedRequiredExtension(String)
    }

    private struct GLTF: Codable {
        struct Buffer: Codable {
            let uri: String?
            let byteLength: Int
        }

        struct BufferView: Codable {
            let buffer: Int
            let byteOffset: Int?
            let byteLength: Int
            let byteStride: Int?
            let target: Int?
        }

        struct Accessor: Codable {
            struct Sparse: Codable {
                struct Indices: Codable {
                    let bufferView: Int
                    let byteOffset: Int?
                    let componentType: Int
                }

                struct Values: Codable {
                    let bufferView: Int
                    let byteOffset: Int?
                }

                let count: Int
                let indices: Indices
                let values: Values
            }

            let bufferView: Int?
            let byteOffset: Int?
            let componentType: Int
            let normalized: Bool?
            let count: Int
            let type: String
            let min: [Float]?
            let max: [Float]?
            let sparse: Sparse?
        }

        struct Mesh: Codable {
            struct Primitive: Codable {
                let attributes: [String: Int]
                let indices: Int?
                let material: Int?
                let mode: Int?
            }

            let name: String?
            let primitives: [Primitive]
        }

        struct Material: Codable {
            struct PBR: Codable {
                struct TextureInfo: Codable {
                    let index: Int
                    let texCoord: Int?
                }

                let baseColorFactor: [Float]?
                let baseColorTexture: TextureInfo?
                let metallicFactor: Float?
                let roughnessFactor: Float?
                let metallicRoughnessTexture: TextureInfo?
            }

            struct NormalTextureInfo: Codable {
                let index: Int
                let texCoord: Int?
                let scale: Float?
            }

            let name: String?
            let pbrMetallicRoughness: PBR?
            let normalTexture: NormalTextureInfo?
        }

        struct Texture: Codable {
            let sampler: Int?
            let source: Int?
        }

        struct Image: Codable {
            let uri: String?
            let mimeType: String?
            let bufferView: Int?
        }

        struct Node: Codable {
            let name: String?
            let children: [Int]?
            let matrix: [Float]?
            let translation: [Float]?
            let rotation: [Float]?
            let scale: [Float]?
            let mesh: Int?
            let camera: Int?
        }

        struct Scene: Codable {
            let nodes: [Int]?
            let name: String?
        }

        let asset: Asset
        let scene: Int?
        let scenes: [Scene]?
        let nodes: [Node]?
        let meshes: [Mesh]?
        let accessors: [Accessor]?
        let bufferViews: [BufferView]?
        let buffers: [Buffer]?
        let materials: [Material]?
        let textures: [Texture]?
        let images: [Image]?
        let extensionsUsed: [String]?
        let extensionsRequired: [String]?

        struct Asset: Codable {
            let version: String
        }
    }
}
