import Foundation

/// Per-request accounting. No mutable state is shared between resource loads.
struct NativeGLTFBudget {
    private(set) var encodedRemaining: Int?
    private let decodedLimit: Int?
    private let encodedLimit: Int?
    private(set) var decodedBytes = 0

    var footprint: ModelImportFootprint? {
        guard let encodedLimit, let encodedRemaining else {
            return nil
        }
        return .init(encodedBytes: encodedLimit - encodedRemaining, decodedBytes: decodedBytes)
    }

    init(rootBytes: Int) throws {
        if let limits = ModelImportContext.limits {
            guard limits.maximumEncodedBytes > 0, limits.maximumDecodedBytes > 0 else { throw ModelImportLimitError.invalidLimits }
            guard rootBytes <= limits.maximumEncodedBytes else { throw ModelImportLimitError.encodedBudgetExceeded }
            encodedRemaining = limits.maximumEncodedBytes - rootBytes
            decodedLimit = limits.maximumDecodedBytes
            encodedLimit = limits.maximumEncodedBytes
        } else {
            encodedRemaining = nil
            decodedLimit = nil
            encodedLimit = nil
        }
    }

    mutating func consumeEncoded(_ count: Int) throws {
        guard let remaining = encodedRemaining else {
            return
        }
        guard count >= 0, count <= remaining else { throw ModelImportLimitError.encodedBudgetExceeded }
        encodedRemaining = remaining - count
    }

    mutating func read(_ url: URL) throws -> Data {
        guard let limit = encodedRemaining else {
            return try Data(contentsOf: url)
        }
        #if WASM
            // A synchronous importer cannot fetch dependencies through a browser stream.
            throw AssetError.message("Bounded synchronous model dependency reads are unavailable in the browser")
        #else
            try Task.checkCancellation()
            guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AssetError.notExistAtPath(url.path)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard try file.seekToEnd() <= UInt64(limit) else { throw ModelImportLimitError.encodedBudgetExceeded }
            try file.seek(toOffset: 0)
            var result = Data()
            while true {
                try Task.checkCancellation()
                let remaining = limit - result.count
                let count = remaining >= 65_536 ? 65_536 : remaining + 1
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else { throw ModelImportLimitError.encodedBudgetExceeded }
                result.append(chunk)
            }
            try consumeEncoded(result.count)
            return result
        #endif
    }

    /// Check decoded URI length before Foundation creates its Data. The root document already bounds strings.
    func preflightDataURI(_ uri: String) throws {
        guard let remaining = encodedRemaining, let comma = uri.firstIndex(of: ",") else {
            return
        }
        let metadata = uri[..<comma]
        let payload = uri[uri.index(after: comma)...]
        let count: Int
        if metadata.hasSuffix(";base64") {
            let length = payload.utf8.count
            guard length.isMultiple(of: 4) else { throw NativeGLTFLoader.GLTFError.invalidDataURI }
            let padding = payload.suffix(2).filter { $0 == "=" }.count
            count = length / 4 * 3 - padding
        } else {
            var bytes = payload.utf8.makeIterator()
            var decoded = 0
            while let byte = bytes.next() {
                decoded += 1
                if byte == 37 {
                    guard bytes.next() != nil, bytes.next() != nil else { throw NativeGLTFLoader.GLTFError.invalidDataURI }
                }
            }
            count = decoded
        }
        guard count >= 0, count <= remaining else { throw ModelImportLimitError.encodedBudgetExceeded }
    }

    /// Charge every decoding reference, including repeated primitive uses of the same accessor.
    /// The conservative stride covers Double scratch, Float results and derived geometry copies.
    mutating func preflight(_ gltf: NativeGLTFLoader.GLTF) throws {
        guard let decodedLimit else {
            return
        }
        var remaining = decodedLimit
        func charge(_ count: Int, stride: Int) throws {
            guard count >= 0, stride > 0, count <= remaining / stride else { throw ModelImportLimitError.decodedBudgetExceeded }
            remaining -= count * stride
        }
        let accessors = gltf.accessors ?? []
        func accessor(_ index: Int) throws {
            guard accessors.indices.contains(index) else { throw NativeGLTFLoader.GLTFError.invalidAccessorIndex(index) }
            let value = accessors[index]
            let components: Int
            switch value.type {
            case "SCALAR": components = 1
            case "VEC2": components = 2
            case "VEC3": components = 3
            case "VEC4", "MAT2": components = 4
            case "MAT3": components = 9
            case "MAT4": components = 16
            default: throw NativeGLTFLoader.GLTFError.invalidAccessorType(value.type)
            }
            guard value.count >= 1 else { throw NativeGLTFLoader.GLTFError.bufferOutOfBounds }
            try charge(value.count, stride: components * 64)
            if let sparse = value.sparse {
                guard sparse.count >= 1, sparse.count <= value.count else { throw NativeGLTFLoader.GLTFError.sparseIndexOutOfBounds }
                try charge(sparse.count, stride: components * 16 + 8)
            }
        }
        try charge(gltf.nodes?.count ?? 0, stride: 256)
        try charge(gltf.materials?.count ?? 0, stride: 512)
        try charge(gltf.images?.count ?? 0, stride: 128)
        try charge(gltf.accessors?.count ?? 0, stride: 128)
        try charge(gltf.buffers?.count ?? 0, stride: 64)
        try charge(gltf.bufferViews?.count ?? 0, stride: 64)
        try charge(gltf.textures?.count ?? 0, stride: 64)
        try charge(gltf.samplers?.count ?? 0, stride: 64)
        for node in gltf.nodes ?? [] {
            try charge(node.children?.count ?? 0, stride: 8)
            try charge(node.weights?.count ?? 0, stride: 8)
        }
        for scene in gltf.scenes ?? [] {
            try charge(1, stride: 128)
            try charge(scene.nodes?.count ?? 0, stride: 8)
        }
        for image in gltf.images ?? [] {
            if image.uri == nil, let index = image.bufferView {
                guard let views = gltf.bufferViews, views.indices.contains(index) else { throw NativeGLTFLoader.GLTFError.invalidBufferViewIndex(index) }
                // Conversion retains a separate Data for every image reference, even when views repeat.
                try charge(views[index].byteLength, stride: 1)
            }
        }
        for mesh in gltf.meshes ?? [] {
            try Task.checkCancellation()
            try charge(1, stride: 128)
            try charge(mesh.weights?.count ?? 0, stride: 8)
            for name in mesh.extras?.targetNames ?? [] { try charge(name.utf8.count, stride: 1) }
            for primitive in mesh.primitives {
                try charge(1, stride: 128)
                for index in primitive.attributes.values { try accessor(index) }
                if let index = primitive.indices { try accessor(index) }
                for target in primitive.targets ?? [] {
                    // Empty targets still create three array fields and synthesized default weights.
                    try charge(1, stride: 128)
                    for index in target.values { try accessor(index) }
                }
            }
        }
        for skin in gltf.skins ?? [] {
            try charge(skin.joints.count, stride: 128)
            if let index = skin.inverseBindMatrices { try accessor(index) }
        }
        for animation in gltf.animations ?? [] {
            try Task.checkCancellation()
            for sampler in animation.samplers {
                try accessor(sampler.input)
                try accessor(sampler.output)
            }
            try charge(animation.channels.count, stride: 128)
        }
        decodedBytes = decodedLimit - remaining
    }
}
