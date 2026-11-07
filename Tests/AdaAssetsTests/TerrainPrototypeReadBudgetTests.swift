import AdaAssets
import Foundation
import Testing

@Suite("Terrain prototype import read budgets")
struct TerrainPrototypeReadBudgetTests {
    private func document(count: Int = 3, primitives: Int = 1, buffer: String? = nil, image: String? = nil) throws -> Data {
        var accessor: [String: Any] = ["componentType": 5126, "count": count, "type": "VEC3"]
        var value: [String: Any] = [
            "asset": ["version": "2.0"],
            "meshes": [["primitives": Array(repeating: ["attributes": ["POSITION": 0]], count: primitives)]],
            "nodes": [["mesh": 0]], "scenes": [["nodes": [0]]], "scene": 0,
        ]
        if let buffer {
            accessor["bufferView"] = 0
            value["buffers"] = [["uri": buffer, "byteLength": 36]]
            value["bufferViews"] = [["buffer": 0, "byteLength": 36]]
        }
        if let image { value["images"] = [["uri": image]] }
        value["accessors"] = [accessor]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("TerrainImportBudget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @Test("Decoded accessors and repeated primitive references are bounded before expansion")
    func terrainPrototypeDecodedReadBudget() throws {
        for data in [try document(count: 1_023), try document(primitives: 32)] {
            let unconstrained = try NativeGLTFLoader().load(data: data)
            #expect(!unconstrained.meshes.isEmpty)
            #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
                try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 32_768, maximumDecodedBytes: 4_096)) {
                    _ = try NativeGLTFLoader().load(data: data)
                }
            }
        }
    }

    @Test("Root, external buffers and external images share an encoded byte budget")
    func terrainPrototypeEncodedReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(repeating: 0, count: 4_096)
        try payload.write(to: directory.appendingPathComponent("buffer.bin"))
        try payload.write(to: directory.appendingPathComponent("image.png"))
        let fixtures: [(String, Data, Int)] = [
            ("root.gltf", try document(), 64),
            ("buffer.gltf", try document(buffer: "buffer.bin"), 1_024),
            ("image.gltf", try document(image: "image.png"), 1_024),
        ]
        for (name, data, limit) in fixtures {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            _ = try await NativeGLTFLoader().load(url: url)
            await #expect(throws: ModelImportLimitError.encodedBudgetExceeded) {
                try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: limit, maximumDecodedBytes: 32_768)) {
                    _ = try await NativeGLTFLoader().load(url: url)
                }
            }
        }
    }

    @Test("A valid bounded import retains geometry and invalid limits fail explicitly")
    func terrainPrototypeValidReadBudget() throws {
        let data = try document()
        let result = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 4_096)) {
            try NativeGLTFLoader().load(data: data)
        }
        #expect(result.meshes.first?.primitives.first?.attributes[.position]?.count == 3)
        #expect(throws: ModelImportLimitError.invalidLimits) {
            try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 0, maximumDecodedBytes: 4_096)) {
                _ = try NativeGLTFLoader().load(data: data)
            }
        }
    }

    private func binaryDocument(_ value: [String: Any], binary: Data) throws -> Data {
        var json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        while !json.count.isMultiple(of: 4) { json.append(32) }
        var result = Data("glTF".utf8)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            unsafe withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        word(2); word(UInt32(12 + 8 + json.count + 8 + binary.count))
        word(UInt32(json.count)); word(0x4e4f_534a); result.append(json)
        word(UInt32(binary.count)); word(0x004e_4942); result.append(binary)
        return result
    }

    @Test("Repeated embedded image views charge every retained copy before conversion")
    func terrainPrototypeEmbeddedImageReadBudget() throws {
        var value = try #require(JSONSerialization.jsonObject(with: document()) as? [String: Any])
        value["buffers"] = [["byteLength": 4_096]]
        value["bufferViews"] = [["buffer": 0, "byteLength": 4_096]]
        let binary = Data(repeating: 0, count: 4_096)
        value["images"] = [["bufferView": 0, "mimeType": "image/png"]]
        let one = try binaryDocument(value, binary: binary)
        let valid = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: 32_768)) {
            try NativeGLTFLoader().load(data: one)
        }
        #expect(valid.images.first?.data?.count == 4_096)
        value["images"] = Array(repeating: ["bufferView": 0, "mimeType": "image/png"] as [String: Any], count: 32)
        let repeated = try binaryDocument(value, binary: binary)
        #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
            try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: 32_768)) {
                _ = try NativeGLTFLoader().load(data: repeated)
            }
        }
    }

    @Test("Empty morph targets charge retained target metadata and synthesized weights")
    func terrainPrototypeEmptyMorphReadBudget() throws {
        var value = try #require(JSONSerialization.jsonObject(with: document()) as? [String: Any])
        value["meshes"] = [["primitives": [["attributes": ["POSITION": 0], "targets": Array(repeating: [String: Int](), count: 32)]]]]
        let data = try JSONSerialization.data(withJSONObject: value)
        #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
            try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 32_768, maximumDecodedBytes: 4_096)) {
                _ = try NativeGLTFLoader().load(data: data)
            }
        }
    }

    @Test("Maximum unsigned sparse indices reject without narrowing to a platform Int first")
    func terrainPrototypeSparseMaximumIndex() throws {
        let binary = Data([255, 255, 255, 255] + Array(repeating: UInt8(0), count: 12))
        var value = try #require(JSONSerialization.jsonObject(with: document()) as? [String: Any])
        value["buffers"] = [["byteLength": 16, "uri": "data:application/octet-stream;base64," + binary.base64EncodedString()]]
        value["bufferViews"] = [["buffer": 0, "byteLength": 4], ["buffer": 0, "byteOffset": 4, "byteLength": 12]]
        value["accessors"] = [
            [
                "componentType": 5126, "count": 3, "type": "VEC3",
                "sparse": ["count": 1, "indices": ["bufferView": 0, "componentType": 5125], "values": ["bufferView": 1]],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: value)
        #expect(throws: NativeGLTFLoader.GLTFError.sparseIndexOutOfBounds) {
            _ = try NativeGLTFLoader().load(data: data)
        }
    }
}
