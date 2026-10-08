//
//  NamedTextureAtlasTests.swift
//

import AdaAssets
@testable import AdaRender
import Foundation
import Math
import Testing

@Suite("NamedTextureAtlas")
struct NamedTextureAtlasTests {
    @Test
    func atlasRegionCodableRoundTrip() throws {
        let region = AtlasRegion(
            key: "home",
            atlasOrigin: PointInt(x: 2, y: 3),
            atlasSize: SizeInt(width: 16, height: 16),
            uvMin: Vector2(0.1, 0.2),
            uvMax: Vector2(0.3, 0.4),
            originalSize: SizeInt(width: 12, height: 12),
            contentOriginInAtlas: PointInt(x: 4, y: 5)
        )
        let data = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(AtlasRegion.self, from: data)
        #expect(decoded.key == region.key)
        #expect(decoded.atlasOrigin.x == region.atlasOrigin.x)
        #expect(decoded.uvMin.x == region.uvMin.x)
        #expect(decoded.originalSize.width == region.originalSize.width)
        #expect(decoded.contentOriginInAtlas.y == region.contentOriginInAtlas.y)
    }

    @Test
    func descriptorSupportsPathsAndExplicitKeys() throws {
        let data = Data(
            #"{"images":["images/player.png",{"path":"images/enemy.png","key":"enemyIdle"}]}"#.utf8
        )
        let descriptor = try JSONDecoder().decode(NamedTextureAtlas.Descriptor.self, from: data)

        #expect(descriptor.images == [
            NamedTextureAtlas.Source(path: "images/player.png"),
            NamedTextureAtlas.Source(path: "images/enemy.png", key: "enemyIdle")
        ])
        #expect(descriptor.margin == 0)
        #expect(descriptor.padding == 2)
        #expect(descriptor.extrude == 1)
        #expect(descriptor.filter == .linear)
    }

    @Test
    func packerCreatesDeterministicExtrudedRegions() throws {
        let red = Image(width: 2, height: 1, data: Data([255, 0, 0, 255, 128, 0, 0, 255]), format: .rgba8)
        let green = Image(width: 1, height: 1, data: Data([0, 255, 0, 255]), format: .rgba8)
        let descriptor = NamedTextureAtlas.Descriptor(
            images: [],
            margin: 1,
            padding: 2,
            extrude: 1,
            powerOfTwo: true
        )

        let result = try NamedTextureAtlasPacker.pack(
            [
                .init(key: "green", image: green),
                .init(key: "red", image: red)
            ],
            descriptor: descriptor
        )

        #expect(result.image.width == 16)
        #expect(result.image.height == 8)
        #expect(result.entriesByKey.keys.sorted() == ["green", "red"])
        let redRegion = try #require(result.entriesByKey["red"])
        #expect(redRegion.originalSize == SizeInt(width: 2, height: 1))
        #expect(redRegion.atlasOrigin == PointInt(x: 1, y: 1))

        let topLeftExtrudedOffset = (redRegion.atlasOrigin.y * result.image.width + redRegion.atlasOrigin.x) * 4
        #expect(Array(result.image.data[topLeftExtrudedOffset ..< topLeftExtrudedOffset + 4]) == [255, 0, 0, 255])
    }

    @Test
    func rejectsDuplicateKeys() {
        let image = Image(width: 1, height: 1, data: Data([255, 255, 255, 255]), format: .rgba8)

        #expect(throws: NamedTextureAtlasPackingError.self) {
            try NamedTextureAtlasPacker.pack(
                [.init(key: "same", image: image), .init(key: "same", image: image)],
                descriptor: NamedTextureAtlas.Descriptor(images: [])
            )
        }
    }

    @Test
    func loadsAtlasAndNamedSliceAsAssets() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let repositoryURL = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Editor/Sources/AdaEditor/Assets/AdaEngine.png")
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NamedTextureAtlasTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let copiedSourceURL = temporaryURL.appendingPathComponent("AdaEngine.png", isDirectory: false)
        try FileManager.default.copyItem(at: sourceURL, to: copiedSourceURL)
        let atlasURL = temporaryURL.appendingPathComponent("game.atlas", isDirectory: false)
        let descriptor = NamedTextureAtlas.Descriptor(
            images: [.init(path: copiedSourceURL.lastPathComponent, key: "logo")],
            padding: 4,
            extrude: 2,
            filter: .nearest
        )
        try JSONEncoder().encode(descriptor).write(to: atlasURL)

        let atlasHandle = try await AssetsManager.load(NamedTextureAtlas.self, at: atlasURL.path)
        let atlas = try #require(atlasHandle.asset)
        #expect(atlas.keys == ["logo"])
        #expect(atlas.descriptor == descriptor)
        #expect(atlas.texture.sampler.descriptor.minFilter == .nearest)
        #expect(atlas["logo"]?.size == atlas.region(for: "logo")?.originalSize)

        let sliceHandle = try await AssetsManager.load(
            NamedTextureAtlas.Slice.self,
            at: "\(atlasURL.path)#logo"
        )
        let slice = try #require(sliceHandle.asset)
        #expect(slice.size == atlas.region(for: "logo")?.originalSize)
        #expect(slice.namedAtlas.contains("logo"))
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
