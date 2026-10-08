import Foundation

enum EditorAgentModelTextureTools {
    /// Rewrites only material JSON. Binary mesh data remains byte-for-byte identical.
    static func assign(model: URL, textureURI: String, channel: String, material index: Int) throws -> [String: Any] {
        guard ["gltf", "glb"].contains(model.pathExtension.lowercased()),
            ["baseColor", "normal", "metallicRoughness", "emissive", "occlusion"].contains(channel)
        else {
            throw Failure("Expected .gltf/.glb and a supported material channel.")
        }
        let original = try Data(contentsOf: model)
        guard original.count <= 128 * 1024 * 1024 else { throw Failure("Model exceeds 128 MB.") }
        let binary = model.pathExtension.lowercased() == "glb"
        let chunks = binary ? try decodeGLB(original) : []
        guard let jsonData = binary ? chunks.first?.data : original,
            var root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            var materials = root["materials"] as? [[String: Any]], materials.indices.contains(index)
        else {
            throw Failure("Model has no material at this index.")
        }
        var images = root["images"] as? [[String: Any]] ?? []
        var textures = root["textures"] as? [[String: Any]] ?? []
        images.append(["uri": textureURI])
        textures.append(["source": images.count - 1])
        let texture: [String: Any] = ["index": textures.count - 1]
        if channel == "baseColor" || channel == "metallicRoughness" {
            var pbr = materials[index]["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            pbr[channel + "Texture"] = texture
            materials[index]["pbrMetallicRoughness"] = pbr
        } else {
            materials[index][channel + "Texture"] = texture
        }
        root["images"] = images
        root["textures"] = textures
        root["materials"] = materials
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let output = binary ? try encodeGLB(json: encoded, preserving: Array(chunks.dropFirst())) : encoded
        guard try Data(contentsOf: model) == original else { throw Failure("Model changed during editing; retry against the latest file.") }
        try output.write(to: model, options: .atomic)
        return ["material": index, "channel": channel, "textureURI": textureURI, "preservedBinaryChunks": chunks.dropFirst().count, "requiresRebuild": true]
    }

    struct Chunk {
        let type: UInt32
        let data: Data
    }

    static func decodeGLB(_ data: Data) throws -> [Chunk] {
        guard data.count >= 20, read(data, 0) == 0x4654_6C67, read(data, 4) == 2, Int(read(data, 8)) == data.count else {
            throw Failure("Invalid GLB 2.0 header.")
        }
        var result: [Chunk] = []
        var offset = 12
        while offset < data.count {
            guard data.count - offset >= 8 else { throw Failure("Truncated GLB chunk header.") }
            let length = Int(read(data, offset))
            let type = read(data, offset + 4)
            guard length % 4 == 0, length <= data.count - offset - 8 else { throw Failure("Invalid GLB chunk length.") }
            result.append(Chunk(type: type, data: data.subdata(in: (offset + 8)..<(offset + 8 + length))))
            offset += 8 + length
        }
        guard result.first?.type == 0x4E4F_534A, result.filter({ $0.type == 0x4E4F_534A }).count == 1 else { throw Failure("Expected one initial GLB JSON chunk.") }
        return result
    }

    static func encodeGLB(json: Data, preserving chunks: [Chunk]) throws -> Data {
        var padded = json
        while padded.count % 4 != 0 { padded.append(0x20) }
        let all = [Chunk(type: 0x4E4F_534A, data: padded)] + chunks
        let total = 12 + all.reduce(0) { $0 + 8 + $1.data.count }
        guard total <= 128 * 1024 * 1024 else { throw Failure("GLB output exceeds 128 MB.") }
        var data = Data()
        for value in [UInt32(0x4654_6C67), 2, UInt32(total)] { append(value, to: &data) }
        for chunk in all {
            append(UInt32(chunk.data.count), to: &data)
            append(chunk.type, to: &data)
            data.append(chunk.data)
        }
        return data
    }

    private static func read(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << UInt32($1 * 8)) }
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
