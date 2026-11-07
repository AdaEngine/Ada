@_spi(Internal) @testable import AdaAssets
import AdaEngine
import Foundation
import Testing

@Suite("Terrain model image budgets")
struct TerrainPrototypeImageBudgetTests {
    @Test("PNG and native raster pixels respect the scoped decoded budget before allocation")
    func terrainPrototypePixelReadBudget() throws {
        let png = try Image(width: 2, height: 2, data: Data(repeating: 255, count: 16), format: .rgba8).pngData()
        let tga = Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 24, 32] + Array(repeating: UInt8(255), count: 12))
        for data in [png, tga] {
            let valid = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 32)) {
                try Image.decode(from: data)
            }
            #expect(valid.width == 2 && valid.height == 2 && valid.data.count == 16)
            #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
                try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 8)) {
                    _ = try Image.decode(from: data)
                }
            }
        }
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Bounded models admit one small texture but reject aggregate distinct pixel and mip allocations")
    func terrainModelAggregatePixelReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let base = try #require(JSONSerialization.jsonObject(with: terrainGLTFDocument(normals: 3)) as? [String: Any])
        let meshes = try #require(base["meshes"] as? [[String: Any]])
        let primitives = try #require(meshes.first?["primitives"] as? [[String: Any]])
        let primitive = try #require(primitives.first)
        for count in [1, 8] {
            var value = base
            var images: [[String: Any]] = []
            var materials: [[String: Any]] = []
            var textures: [[String: Any]] = []
            var parts: [[String: Any]] = []
            for index in 0..<count {
                var pixels = Data(repeating: 255, count: 4_096)
                for offset in stride(from: 0, to: pixels.count, by: 4) { pixels[offset] = UInt8(index * 31) }
                let data = try Image(width: 32, height: 32, data: pixels, format: .rgba8).pngData()
                images.append(["uri": "data:image/png;base64," + data.base64EncodedString()])
                textures.append(["source": index])
                materials.append(["pbrMetallicRoughness": ["baseColorTexture": ["index": index]]])
                var part = primitive
                part["material"] = index
                parts.append(part)
            }
            value["images"] = images
            value["textures"] = textures
            value["materials"] = materials
            value["meshes"] = [["primitives": parts]]
            let data = try JSONSerialization.data(withJSONObject: value)
            let decoder = TextAssetDecoder(meta: AssetMeta(filePath: directory.appendingPathComponent("decoded.gltf"), queryParams: []), data: data)
            if count == 1 {
                let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: 65_536)) {
                    try await ModelAsset3D(from: decoder)
                }
                #expect(model.meshes.count == 1)
            } else {
                await #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
                    try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: 65_536)) {
                        _ = try await ModelAsset3D(from: decoder)
                    }
                }
            }
        }
    }
}

extension TerrainPrototypeImageBudgetTests {
    @Test("Bounded PNG headers honor nonzero Data slice indices")
    func terrainPrototypeSlicedPNGReadBudget() throws {
        let png = try Image(width: 2, height: 2, data: Data(repeating: 255, count: 16), format: .rgba8).pngData()
        // The first offset reproduces a header error safely, so the pre-fix test exits
        // before trying the larger offset that would index outside the slice.
        for prefix in [8, 100] {
            let padded = Data(repeating: 0, count: prefix) + png
            let slice = padded.dropFirst(prefix)
            #expect(slice.startIndex == prefix)
            let valid = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 32)) {
                try Image.decode(from: slice)
            }
            #expect(valid.width == 2 && valid.height == 2)
            #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
                try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 4_096, maximumDecodedBytes: 8)) {
                    _ = try Image.decode(from: slice)
                }
            }
        }
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Model image admission includes conversion scratch, thin mip chains and retained alpha masks")
    func terrainModelPixelStagingReadBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeApp()
        let cases: [(Int, Int, Bool, Int, Int)] = [(32, 32, false, 5, 2), (1, 32, true, 4, 1)]
        for (width, height, mipmaps, numerator, denominator) in cases {
            let baseBytes = width * height * 4
            var pixels = Data(repeating: 255, count: baseBytes)
            for offset in stride(from: 0, to: baseBytes, by: 4) {
                pixels[offset] = 37; pixels[offset + 1] = 71; pixels[offset + 2] = 109
                pixels[offset + 3] = (offset / 4).isMultiple(of: 2) ? 0 : 255
            }
            let png = try Image(width: width, height: height, data: pixels, format: .rgba8).pngData()
            var value = try #require(JSONSerialization.jsonObject(with: terrainGLTFDocument(normals: 3)) as? [String: Any])
            let meshes = try #require(value["meshes"] as? [[String: Any]])
            let primitives = try #require(meshes.first?["primitives"] as? [[String: Any]])
            var primitive = try #require(primitives.first)
            primitive["material"] = 0
            value["meshes"] = [["primitives": [primitive]]]
            value["images"] = [["uri": "data:image/png;base64," + png.base64EncodedString()]]
            value["samplers"] = [["minFilter": mipmaps ? 9987 : 9729, "magFilter": 9729]]
            value["textures"] = [["source": 0, "sampler": 0]]
            value["materials"] = [["alphaMode": "MASK", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]]]
            let data = try JSONSerialization.data(withJSONObject: value)
            let imported = try ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: 1_048_576)) {
                try NativeGLTFLoader().load(data: data)
            }
            let geometry = try #require(imported.importFootprint?.decodedBytes)
            let tooSmall = geometry + baseBytes * numerator / denominator
            let decoder = TextAssetDecoder(meta: AssetMeta(filePath: directory.appendingPathComponent("staging.gltf"), queryParams: []), data: data)
            // Run the underfunded import first, with unique pixels, to avoid a weak-cache hit.
            await #expect(throws: ModelImportLimitError.decodedBudgetExceeded) {
                try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: tooSmall)) {
                    _ = try await ModelAsset3D(from: decoder)
                }
            }
            let model = try await ModelImportContext.$limits.withValue(.init(maximumEncodedBytes: 65_536, maximumDecodedBytes: geometry + baseBytes * 8)) {
                try await ModelAsset3D(from: decoder)
            }
            #expect(model.meshes.count == 1)
        }
    }
}
