@_spi(Internal) @testable import AdaAssets
import AdaEngine
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    private func boundedOBJDocument(faces: Int = 1) -> Data {
        Data(("v 0 0 0\nv 1 0 0\nv 0 1 0\n" + String(repeating: "f 1 2 3\n", count: faces)).utf8)
    }

    private func boundedVOXDocument(size: UInt32 = 32) -> Data {
        func append(_ value: UInt32, to data: inout Data) {
            var little = value.littleEndian
            unsafe withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func chunk(_ name: String, content: Data) -> Data {
            var data = Data(name.utf8)
            append(UInt32(content.count), to: &data); append(0, to: &data)
            data.append(content)
            return data
        }
        var dimensions = Data()
        append(size, to: &dimensions); append(size, to: &dimensions); append(size, to: &dimensions)
        var cells = Data()
        append(1, to: &cells); cells.append(contentsOf: [0, 0, 0, 1])
        let children = chunk("SIZE", content: dimensions) + chunk("XYZI", content: cells)
        var result = Data("VOX ".utf8)
        append(150, to: &result)
        result.append(Data("MAIN".utf8)); append(0, to: &result); append(UInt32(children.count), to: &result)
        result.append(children)
        return result
    }

    @Test("Bounded OBJ and VOX models reuse supplied root bytes instead of reopening files", arguments: ["obj", "vox"])
    func terrainOtherFormatsReuseDecoderRootBytes(format: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        if format == "obj" { OBJLoaderResolver.shared.setLoader(NativeOBJLoader()) }
        let data = format == "obj" ? boundedOBJDocument() : boundedVOXDocument()
        let decoder = TextAssetDecoder(meta: AssetMeta(filePath: directory.appendingPathComponent("decoded." + format), queryParams: []), data: data)
        let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 1_048_576)) {
            try await ModelAsset3D(from: decoder)
        }
        #expect(model.meshes.count == 1)
    }

    @Test("OBJ parsing meters decoded geometry work before repeated face expansion")
    func terrainOBJDecodedReadBudget() throws {
        let data = boundedOBJDocument(faces: 64)
        let valid = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 1_048_576)) {
            try NativeOBJLoader().load(data: data)
        }
        #expect(!valid.meshes.isEmpty)
        #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
            try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 20_000)) {
                _ = try NativeOBJLoader().load(data: data)
            }
        }
    }

    @Test("OBJ rejects nonfinite coordinates before any model GPU preparation")
    func terrainOBJRejectsNonfiniteCoordinates() throws {
        for word in ["nan", "inf", "-inf"] {
            let data = Data(("v " + word + " 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n").utf8)
            #expect(throws: OBJLoadingError.self) {
                try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 1_048_576)) {
                    _ = try NativeOBJLoader().load(data: data)
                }
            }
        }
    }

    @Test("Sparse VOX occupancy still admits dense-grid and meshing working memory before GPU preparation")
    func terrainVOXDecodedReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let file = directory.appendingPathComponent("sparse.vox")
        let data = boundedVOXDocument()
        try data.write(to: file)
        let decoder = TextAssetDecoder(meta: AssetMeta(filePath: file, queryParams: []), data: data)
        await #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
            try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 8_192)) {
                _ = try await ModelAsset3D(from: decoder)
            }
        }
        let valid = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 1_048_576)) {
            try await ModelAsset3D(from: decoder)
        }
        #expect(valid.meshes.count == 1)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Repeated OBJ faces copy index storage only for amortized array growth")
    func terrainOBJIndexCopyWorkIsLinear() throws {
        let data = boundedOBJDocument(faces: 10_000)
        let result = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 1_048_576, maximumDecodedBytes: 32 * 1_024 * 1_024)) {
            try NativeOBJLoader().load(data: data)
        }
        let indices = result.meshes.flatMap { $0.primitives }.reduce(0) { $0 + $1.indices.count }
        let diagnostics = try #require(result.importDiagnostics)
        #expect(diagnostics.faces == 10_000 && indices == 30_000)
        #expect(diagnostics.copiedIndexBytes <= UInt64(indices * MemoryLayout<UInt32>.stride * 4))
    }

    @Test("Raw VOX frame records consume decoded budget before array reservation")
    func terrainVOXRawFrameReadBudget() throws {
        let count = 2_048
        var content = Data()
        func word(_ value: UInt32, into data: inout Data) {
            var little = value.littleEndian
            unsafe withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(0, into: &content); word(0, into: &content); word(1, into: &content)
        word(UInt32.max, into: &content); word(UInt32.max, into: &content); word(UInt32(count), into: &content)
        for _ in 0..<count { word(0, into: &content) }
        var chunk = Data("nTRN".utf8)
        word(UInt32(content.count), into: &chunk); word(0, into: &chunk); chunk.append(content)
        var data = boundedVOXDocument()
        data.append(chunk)
        var length = UInt32(data.count - 20).littleEndian
        unsafe withUnsafeBytes(of: &length) { data.replaceSubrange(16..<20, with: $0) }
        let rawAllowance = data.count * 16 + 4_096
        #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
            try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: rawAllowance)) {
                _ = try VOXLoader().load(data: data)
            }
        }
        let enough = rawAllowance + MemoryLayout<VOXTransformFrame>.stride * count + 8_192
        let valid = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: enough)) {
            try VOXLoader().load(data: data)
        }
        guard case let .transform(node)? = valid.nodes[0] else {
            Issue.record("Missing transform frame records")
            return
        }
        #expect(node.frames.count == count)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Malformed VOX UTF-8 tags and dictionary strings reject explicitly")
    func terrainVOXRejectsMalformedUTF8() throws {
        func append(_ value: UInt32, to data: inout Data) {
            var little = value.littleEndian
            unsafe withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        var material = Data()
        append(1, to: &material); append(1, to: &material)
        append(1, to: &material); material.append(255)
        append(1, to: &material); material.append(49)
        let cases: [(Data, Data)] = [(Data([255, 88, 89, 90]), Data()), (Data("MATL".utf8), material)]
        for (tag, payload) in cases {
            var chunk = tag
            append(UInt32(payload.count), to: &chunk); append(0, to: &chunk); chunk.append(payload)
            var data = boundedVOXDocument()
            data.append(chunk)
            var children = UInt32(data.count - 20).littleEndian
            unsafe withUnsafeBytes(of: &children) { data.replaceSubrange(16..<20, with: $0) }
            #expect(throws: VOXLoadingError.self) {
                try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 1_048_576)) {
                    _ = try VOXLoader().load(data: data)
                }
            }
        }
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Distinct OBJ materials use indexed primitive selection instead of quadratic searches")
    func terrainOBJMaterialLookupIsLinear() throws {
        var text = "v 0 0 0\nv 1 0 0\nv 0 1 0\n"
        for index in 0..<10_000 { text += "usemtl m" + String(index) + "\nf 1 2 3\n" }
        let result = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 1_048_576, maximumDecodedBytes: 64 * 1_024 * 1_024)) {
            try NativeOBJLoader().load(data: Data(text.utf8))
        }
        let diagnostics = try #require(result.importDiagnostics)
        #expect(result.meshes.flatMap { $0.primitives }.count == 10_000)
        #expect(diagnostics.materialComparisons <= 40_000)
    }
}
