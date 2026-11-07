import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Malformed glTF vertex streams are rejected from real files before model upload")
    func terrainPrototypeRejectsMalformedGLTFBeforeUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerrainImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, normals, invalidIndex, nonfinite) in [
            ("extra-normal", 4, false, false), ("missing-normal", 2, false, false),
            ("bad-index", 3, true, false), ("nonfinite", 3, false, true),
        ] {
            let url = directory.appendingPathComponent(name + ".gltf")
            try terrainGLTFDocument(normals: normals, invalidIndex: invalidIndex, nonfinite: nonfinite).write(to: url)
            await #expect(throws: (any Error).self) { try await NativeGLTFLoader().load(url: url) }
        }
        let valid = directory.appendingPathComponent("valid.gltf")
        try terrainGLTFDocument(normals: 3).write(to: valid)
        let result = try await NativeGLTFLoader().load(url: valid)
        #expect(result.meshes.first?.primitives.first?.attributes[.normal]?.count == 3)
        #expect(result.meshes.first?.primitives.first?.indices == [0, 1, 2])
    }

    @Test("Programmatic vertex upload allocates position rows and safely handles extra or missing attributes")
    func terrainPrototypeUploadUsesPositionCount() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        var descriptor = MeshDescriptor(name: "Mismatched programmatic attributes")
        let positions = [Vector3(0, 1, 0), Vector3(-1, -1, 0), Vector3(1, -1, 0)]
        let normals = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        let stride = MemoryLayout<Vector3>.stride * 2
        let expected = positions.count * stride
        #expect(descriptor.getVertexBufferSize() == expected)
        // Do not invoke the known unsafe legacy writer until its allocation recipe is corrected.
        guard descriptor.getVertexBufferSize() == expected else {
            return
        }
        let buffer = descriptor.getVertexBuffer(renderDevice: device)
        #expect(buffer.length == expected)
        for index in positions.indices {
            #expect(unsafe buffer.contents().load(fromByteOffset: index * stride, as: Vector3.self) == positions[index])
            #expect(unsafe buffer.contents().load(fromByteOffset: index * stride + MemoryLayout<Vector3>.stride, as: Vector3.self) == normals[index])
        }
        descriptor.normals = MeshBuffer(Array(normals.prefix(2)))
        #expect(descriptor.getVertexBufferSize() == expected)
        let missing = descriptor.getVertexBuffer(renderDevice: device)
        #expect(missing.length == expected)
        #expect(unsafe missing.contents().load(fromByteOffset: 2 * stride, as: Vector3.self) == positions[2])
        #expect(unsafe missing.contents().load(fromByteOffset: 2 * stride + MemoryLayout<Vector3>.stride, as: Vector3.self) == .zero)
    }

    func terrainGLTFDocument(normals: Int, invalidIndex: Bool = false, nonfinite: Bool = false) throws -> Data {
        var buffer = Data()
        func word(_ value: UInt32) {
            var little = value.littleEndian
            unsafe withUnsafeBytes(of: &little) { buffer.append(contentsOf: $0) }
        }
        for value in [Float(0), 1, 0, -1, -1, 0, 1, -1, 0] { word(value.bitPattern) }
        for index in 0..<(normals * 3) {
            let value: Float = nonfinite && index == 0 ? .infinity : (index % 3 == 2 ? 1 : 0)
            word(value.bitPattern)
        }
        let indexOffset = buffer.count
        for value in [UInt32(0), 1, invalidIndex ? UInt32.max : 2] { word(value) }
        let document: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 36],
                ["buffer": 0, "byteOffset": 36, "byteLength": normals * 12],
                ["buffer": 0, "byteOffset": indexOffset, "byteLength": 12],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5126, "count": normals, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5125, "count": 3, "type": "SCALAR"],
            ],
            "meshes": [["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "indices": 2]]]],
            "nodes": [["mesh": 0]], "scenes": [["nodes": [0]]], "scene": 0,
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }
}
