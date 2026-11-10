import AdaAssets
@_spi(Internal) import AdaRender
@testable import AdaScene
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    /// Material import decodes distinct textures on several threads; results must match the serial contract.
    @Suite("glTF parallel texture import on GPU")
    @MainActor
    struct ParallelTextureImport {
        private static func png(_ size: Int, _ value: UInt8) throws -> Data {
            try PNGWriter().encode(width: size, height: size, rgba: [UInt8](repeating: value, count: size * size * 4))
        }

        private static func material(base: Int?, metallicRoughness: Int? = nil, normal: Int? = nil) -> GLTFImportResult.Material {
            GLTFImportResult.Material(
                name: nil, baseColorFactor: .one, baseColorTextureIndex: base, metallicFactor: 0, roughnessFactor: 0.5,
                metallicRoughnessTextureIndex: metallicRoughness, normalTextureIndex: normal
            )
        }

        private static func result(materials: [GLTFImportResult.Material], images: [Data]) -> GLTFImportResult {
            GLTFImportResult(
                nodes: [], meshes: [], materials: materials,
                textures: images.indices.map { .init(source: $0, sampler: nil) },
                images: images.map { .init(uri: nil, data: $0, mimeType: "image/png") },
                scenes: [], defaultScene: nil
            )
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func distinctTexturesAreSharedSizedAndMipped() async throws {
            _ = try await Render3DDebugViewGPUTests.makeScene()
            let images = [try Self.png(2, 40), try Self.png(4, 80), try Self.png(8, 120)]
            let materials = try ModelAsset3D.makeMaterials(Self.result(materials: [
                Self.material(base: 0, metallicRoughness: 1, normal: 1),
                Self.material(base: 1, normal: 2),
                Self.material(base: 0),
            ], images: images)).compactMap { $0 as? PBRMaterial }
            #expect(materials.count == 3)
            let first = try #require(materials[0].baseColorTexture)
            #expect(materials[2].baseColorTexture === first, "One texture index and color space must yield one texture.")
            #expect(first.width == 2 && first.mipmapLevelCount == 2)
            let normal = try #require(materials[1].normalTexture)
            #expect(normal.width == 8 && normal.mipmapLevelCount == 4)
            // The same image as sRGB base color and as linear data are distinct textures.
            #expect(materials[1].baseColorTexture !== materials[0].metallicRoughnessTexture)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func anUndecodableTextureFailsTheImport() async throws {
            _ = try await Render3DDebugViewGPUTests.makeScene()
            let images = [try Self.png(2, 40), Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), try Self.png(4, 80)]
            #expect(throws: (any Error).self) {
                try ModelAsset3D.makeMaterials(Self.result(materials: [
                    Self.material(base: 0), Self.material(base: 1), Self.material(base: 2),
                ], images: images))
            }
        }
    }
}
