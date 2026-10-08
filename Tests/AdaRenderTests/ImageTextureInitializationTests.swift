//
//  ImageTextureInitializationTests.swift
//  AdaEngine
//

@testable import AdaRender
import Foundation
import Testing

@Suite("Image Texture Initialization", .serialized)
struct ImageTextureInitializationTests {

    @Test(arguments: ["red.jpg", "pixels.bmp", "pixels.tga"])
    func textureCanInitializeFromDecodedImage(fileName: String) throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        let url = try #require(Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Images"))
        let image = try Image(contentsOf: url)
        let texture = Texture2D(image: image)
        let readback = Image(texture: texture)
        #expect(texture.width == image.width)
        #expect(texture.height == image.height)
        #expect(readback.data == image.data)
    }

    @Test
    func imageCanInitializeFromTexture2D() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        var samplerDescription = SamplerDescriptor(
            minFilter: .linear,
            magFilter: .linear,
            mipFilter: .notMipmapped
        )
        samplerDescription.lodMaxClamp = 8

        var sourceImage = Image(
            width: 2,
            height: 1,
            data: Data([255, 0, 0, 255, 0, 255, 0, 128]),
            format: .rgba8
        )
        sourceImage.samplerDescription = samplerDescription

        let texture = Texture2D(image: sourceImage)
        let image = Image(texture: texture)

        #expect(image.width == sourceImage.width)
        #expect(image.height == sourceImage.height)
        #expect(image.format == sourceImage.format)
        #expect(image.data == sourceImage.data)
        #expect(image.samplerDescription.minFilter == samplerDescription.minFilter)
        #expect(image.samplerDescription.magFilter == samplerDescription.magFilter)
        #expect(image.samplerDescription.mipFilter == samplerDescription.mipFilter)
        #expect(image.samplerDescription.lodMaxClamp == samplerDescription.lodMaxClamp)
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
