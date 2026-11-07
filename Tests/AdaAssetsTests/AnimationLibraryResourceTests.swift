import AdaAnimation
@testable import AdaAssets
import Foundation
import Testing

@Suite
struct AnimationLibraryResourceTests {
    @Test
    func persistsPortableJSONThroughProductionAssetCodecs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationLibrary-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("hero.animlib")
        let meta = AssetMeta(filePath: path, queryParams: [])
        let library = AnimationLibrary(id: "hero", binding: .init(sourceAsset: "hero.glb", nodes: []), clips: [
            .init(id: "idle", name: "Idle", duration: 2)
        ])
        let resource = try AnimationLibraryResource(library: library)
        let encoder = TextAssetEncoder(meta: meta)
        try await resource.encodeContents(with: encoder)
        let data = try #require(encoder.encodedData)
        try data.write(to: path)
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        let loaded = try await AnimationLibraryResource(from: TextAssetDecoder(meta: meta, data: Data(contentsOf: path)))
        #expect(loaded.library == library)
        #expect(AnimationLibraryResource.extensions() == ["animlib"])
    }

    @Test
    func resourceRejectsInvalidDecodedLibrary() async throws {
        let meta = AssetMeta(filePath: URL(fileURLWithPath: "/hero.animlib"), queryParams: [])
        let invalid = AnimationLibrary(binding: .init(sourceAsset: "hero.glb", nodes: []), version: 99)
        let data = try JSONEncoder().encode(invalid)
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await AnimationLibraryResource(from: TextAssetDecoder(meta: meta, data: data))
        }
    }

    @Test(arguments: [-1, 0, 1])
    func publicImportAdapterRejectsMissingSamplerIndices(_ index: Int) {
        let animation = GLTFImportResult.Animation(name: "Malformed", samplers: [], channels: [
            .init(samplerIndex: index, nodeIndex: 0, path: .translation)
        ])
        #expect(throws: SkeletalAnimationError.invalidTrack) {
            _ = try GLTFAnimationAdapter.makeClips([animation])
        }
    }

    @Test
    func authoringImportRestrictsDependenciesAndTotalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationImport-\(UUID())", isDirectory: true)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appendingPathComponent("outside.bin"))
        let escaping = Data(#"{"asset":{"version":"2.0"},"buffers":[{"byteLength":1,"uri":"../outside.bin"}]}"#.utf8)
        #expect(throws: NativeGLTFLoader.GLTFError.self) { _ = try NativeGLTFLoader(resourceRoot: assets).load(data: escaping, baseURL: assets) }
        try Data(repeating: 0, count: 4096).write(to: assets.appendingPathComponent("large.bin"))
        let large = Data(#"{"asset":{"version":"2.0"},"buffers":[{"byteLength":4096,"uri":"large.bin"}]}"#.utf8)
        #expect(throws: NativeGLTFLoader.GLTFError.self) {
            _ = try NativeGLTFLoader(resourceRoot: assets, maximumTotalBytes: 1024).load(data: large, baseURL: assets)
        }
    }
}
