//
//  NativeGLTFLoader.swift
//  AdaEngine
//
//  Created by v.prusakov on 05/30/24.
//

import Foundation
import Math
import Synchronization

public struct NativeGLTFLoader: GLTFLoader {
    private let resourceBoundary: URL?
    private let maximumTotalBytes: Int?

    public init() {
        resourceBoundary = nil
        maximumTotalBytes = nil
    }

    /// Restricts external dependencies and bounds input/resource bytes plus cumulative accessor decoding work.
    /// The ordinary loader retains its existing project-scope behavior when this initializer is unused.
    public init(resourceRoot: URL, maximumTotalBytes: Int = 32 * 1024 * 1024) {
        resourceBoundary = resourceRoot.resolvingSymlinksInPath().standardizedFileURL
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }

    public func load(url: URL) async throws -> GLTFImportResult {
        if let root = resourceBoundary {
            // Authoring callers resolve a canonical regular file before loading. Recheck immediately
            // before opening it so a replaced parent junction cannot redirect the primary model.
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard url.isFileURL, root.isFileURL,
                root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
                canonical.path == url.standardizedFileURL.path,
                canonical.path.hasPrefix(root.path + "/"),
                try canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw GLTFError.invalidDataURI
            }
        }
        let data: Data
        if let maximumTotalBytes {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: min(maximumTotalBytes, Int.max - 1) + 1) ?? Data()
        } else {
            var budget = try NativeGLTFBudget(rootBytes: 0)
            data = try budget.read(url)
        }
        return try load(data: data, baseURL: url.deletingLastPathComponent())
    }

    /// Loads a glTF or GLB document from memory.
    /// The glTF extensions this loader implements. A file that *requires* any other extension fails to load; an
    /// extension it merely *uses* is ignored and reported in ``GLTFImportResult/warnings``.
    public static let supportedExtensions: Set<String> = [
        "KHR_mesh_quantization",
        "KHR_materials_emissive_strength",
        "KHR_texture_transform",
        "KHR_materials_ior",
        "KHR_materials_specular",
        "KHR_materials_clearcoat",
        "KHR_materials_sheen",
        "KHR_materials_anisotropy",
    ]

    /// Optional content the importer cannot honor: extensions the file lists as used that are not implemented.
    private func warnings(for gltf: GLTF) -> [String] {
        var result: [String] = []
        for name in (gltf.extensionsUsed ?? []).sorted() where !Self.supportedExtensions.contains(name) {
            result.append("The extension \(name) is not supported and was ignored.")
        }
        for (index, mesh) in (gltf.meshes ?? []).enumerated() {
            let ignored = Set(mesh.primitives.flatMap { $0.targets ?? [] }.flatMap(\.keys)).subtracting(["POSITION", "NORMAL", "TANGENT"])
            if !ignored.isEmpty {
                result.append("Mesh \(index) morphs \(ignored.sorted().joined(separator: ", ")); only POSITION, NORMAL and TANGENT deltas were applied.")
            }
        }
        return result
    }

    public func load(data: Data, baseURL: URL? = nil, allowExternalResources: Bool = true) throws -> GLTFImportResult {
        if let maximumTotalBytes, data.count > maximumTotalBytes { throw GLTFError.bufferOutOfBounds }
        var budget = try NativeGLTFBudget(rootBytes: data.count)
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

        if let unsupportedExtension = gltf.extensionsRequired?.first(where: { !Self.supportedExtensions.contains($0) }) {
            throw GLTFError.unsupportedRequiredExtension(unsupportedExtension)
        }

        if let maximumTotalBytes {
            try validateDecodedWork(gltf, maximumBytes: maximumTotalBytes)
            var remaining = maximumTotalBytes - data.count
            let uris = (gltf.buffers ?? []).compactMap(\.uri) + (gltf.images ?? []).compactMap(\.uri)
            for uri in uris {
                let count: Int
                if uri.hasPrefix("data:") {
                    guard let comma = uri.firstIndex(of: ",") else { throw GLTFError.invalidDataURI }
                    let payloadBytes = uri[uri.index(after: comma)...].utf8.count
                    count = uri[..<comma].hasSuffix(";base64") ? payloadBytes / 4 * 3 : payloadBytes
                } else {
                    let url = try resourceURL(uri, relativeTo: resourceBaseURL)
                    count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? remaining + 1
                }
                guard count <= remaining else { throw GLTFError.bufferOutOfBounds }
                remaining -= count
            }
        }
        if !allowExternalResources {
            let uris = (gltf.buffers ?? []).compactMap(\.uri) + (gltf.images ?? []).compactMap(\.uri)
            guard uris.allSatisfy({ $0.hasPrefix("data:") }) else { throw GLTFError.invalidDataURI }
        }
        try budget.preflight(gltf)
        let buffers = try loadBuffers(gltf.buffers ?? [], baseURL: resourceBaseURL, binaryBuffer: binaryBuffer, budget: &budget)

        var result = try convertToImportResult(gltf, buffers: buffers, baseURL: resourceBaseURL, budget: &budget)
        result.importFootprint = budget.footprint
        try result.validateGeometry()
        return result
    }

    /// Bounds allocations before decodeAccessor creates zero-filled storage, including sparse/unused accessors.
    /// Charge every decode reference: sharing an accessor does not make repeated decoding free.
    private func validateDecodedWork(_ gltf: GLTF, maximumBytes: Int) throws {
        let inventories = [gltf.nodes?.count, gltf.meshes?.count, gltf.materials?.count, gltf.skins?.count,
                           gltf.animations?.count, gltf.textures?.count, gltf.images?.count, gltf.accessors?.count,
                           gltf.bufferViews?.count, gltf.buffers?.count]
        guard inventories.allSatisfy({ ($0 ?? 0) <= 16_384 }) else { throw GLTFError.bufferOutOfBounds }
        let maximumElements = maximumBytes / MemoryLayout<Double>.stride
        let costs = try (gltf.accessors ?? []).map { accessor -> Int in
            let components = try componentCount(for: accessor.type)
            guard accessor.count > 0, accessor.count <= maximumElements / components else { throw GLTFError.bufferOutOfBounds }
            var cost = accessor.count * components
            if let sparse = accessor.sparse {
                guard sparse.count > 0, sparse.count <= accessor.count else { throw GLTFError.bufferOutOfBounds }
                // decodeAccessor retains the dense values while decoding sparse values and Int indices.
                let temporary = sparse.count * (components + 1)
                guard temporary <= maximumElements - cost else { throw GLTFError.bufferOutOfBounds }
                cost += temporary
            }
            return cost
        }
        var remaining = maximumElements
        func charge(_ index: Int) throws {
            guard costs.indices.contains(index), costs[index] <= remaining else { throw GLTFError.bufferOutOfBounds }
            remaining -= costs[index]
        }
        for mesh in gltf.meshes ?? [] {
            guard mesh.primitives.count <= 4_096 else { throw GLTFError.bufferOutOfBounds }
            for primitive in mesh.primitives {
                for index in primitive.attributes.values { try charge(index) }
                if let index = primitive.indices { try charge(index) }
                for target in primitive.targets ?? [] { for index in target.values { try charge(index) } }
            }
        }
        for animation in gltf.animations ?? [] {
            guard animation.samplers.count <= 4_096, animation.channels.count <= 4_096 else { throw GLTFError.bufferOutOfBounds }
            for sampler in animation.samplers { try charge(sampler.input); try charge(sampler.output) }
        }
        for skin in gltf.skins ?? [] { if let index = skin.inverseBindMatrices { try charge(index) } }
    }

    private func parseGLB(_ data: Data) throws -> (GLTF, Data?) {
        guard data.count >= 12 else {
            throw GLTFError.invalidGLB
        }
        let magic = data.subdata(in: 0..<4)
        let version = readUInt32(data, at: 4)
        guard let declaredLength = Int(exactly: readUInt32(data, at: 8)) else { throw GLTFError.invalidGLB }

        if magic != Data("glTF".utf8) || version != 2 || declaredLength != data.count {
            throw GLTFError.invalidGLB
        }

        var offset = 12
        var gltf: GLTF?
        var binaryBuffer: Data?

        while offset < data.count {
            guard offset <= data.count - 8 else {
                throw GLTFError.invalidGLB
            }
            guard let chunkLength = Int(exactly: readUInt32(data, at: offset)) else { throw GLTFError.invalidGLB }
            let chunkType = readUInt32(data, at: offset + 4)
            guard chunkLength <= data.count - offset - 8 else {
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

    private func loadBuffers(_ gltfBuffers: [GLTF.Buffer], baseURL: URL, binaryBuffer: Data?, budget: inout NativeGLTFBudget) throws -> [Data] {
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
                try budget.preflightDataURI(uri)
                let data = try decodeDataURI(uri)
                try budget.consumeEncoded(data.count)
                buffers.append(data)
            } else {
                let bufferURL = try resourceURL(uri, relativeTo: baseURL)
                let data = try budget.read(bufferURL)
                buffers.append(data)
            }

            guard buffers.last?.count ?? 0 >= buffer.byteLength else {
                throw GLTFError.bufferTooShort
            }
        }

        return buffers
    }

    /// Reads external image files concurrently. Failed reads are omitted, so the serial path reports their errors.
    private func prefetchExternalImages(_ images: [GLTF.Image], baseURL: URL) -> [URL: Data] {
        #if WASM
            return [:]
        #else
            let urls = Array(Set(images.compactMap { image -> URL? in
                guard let uri = image.uri, !uri.starts(with: "data:") else { return nil }
                return try? resourceURL(uri, relativeTo: baseURL)
            }))
            guard urls.count > 1 else { return [:] }
            let output = Mutex<[URL: Data]>([:])
            let workers = min(urls.count, 8)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for index in stride(from: worker, to: urls.count, by: workers) {
                    guard let data = try? Data(contentsOf: urls[index]) else { continue }
                    output.withLock { $0[urls[index]] = data }
                }
            }
            return output.withLock { $0 }
        #endif
    }

    private func convertToImportResult(_ gltf: GLTF, buffers: [Data], baseURL: URL, budget: inout NativeGLTFBudget) throws -> GLTFImportResult {
        let prefetched = budget.isUnbounded ? prefetchExternalImages(gltf.images ?? [], baseURL: baseURL) : [:]
        let images = try (gltf.images ?? [])
            .map { image -> GLTFImportResult.Image in
                if let uri = image.uri {
                    if uri.starts(with: "data:") {
                        try budget.preflightDataURI(uri)
                        let data = try decodeDataURI(uri)
                        try budget.consumeEncoded(data.count)
                        return GLTFImportResult.Image(uri: nil, data: data, mimeType: image.mimeType)
                    }
                    let imageURL = try resourceURL(uri, relativeTo: baseURL)
                    return try GLTFImportResult.Image(uri: imageURL, data: prefetched[imageURL] ?? budget.read(imageURL), mimeType: image.mimeType)
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

        let meshes = try (gltf.meshes ?? []).enumerated()
            .map { meshIndex, mesh -> GLTFImportResult.Mesh in
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
                        skinning: importSkinning(primitive, attributes: attributes, gltf: gltf),
                        morphTargets: importMorphTargets(primitive, attributes: attributes, gltf: gltf, buffers: buffers, meshIndex: meshIndex)
                    )
                }

                let morph = try importMorphMetadata(mesh, primitives: primitives, meshIndex: meshIndex)
                return GLTFImportResult.Mesh(name: mesh.name, primitives: primitives, defaultWeights: morph.weights, targetNames: morph.names)
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
            samplers: samplers,
            warnings: warnings(for: gltf)
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
        guard offset >= 0, offset <= buffer.count, bufferView.byteLength >= 0, bufferView.byteLength <= buffer.count - offset else {
            throw GLTFError.bufferOutOfBounds
        }
        return buffer.subdata(in: offset..<offset + bufferView.byteLength)
    }

    private func resourceURL(_ uri: String, relativeTo base: URL) throws -> URL {
        let decoded = uri.removingPercentEncoding ?? uri
        let target = base.appendingPathComponent(decoded).standardizedFileURL
        if let root = resourceBoundary ?? AssetsManager.restrictedResourceRoot {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\"),
                !decoded.contains("?"), !decoded.contains("#"), canonicalTarget.hasPrefix(canonicalRoot + "/")
            else {
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
