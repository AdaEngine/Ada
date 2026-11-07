@_spi(Internal) @testable import AdaRender
import Math
import Testing

@Suite(.serialized)
struct Texture2DProxyTests {
    @Test("Incremental uploads use the captured proxy backing's actual slice and mip layout")
    func textureProxySubresources() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        var descriptor = TextureDescriptor(width: 2, height: 2, pixelFormat: .rgba8, textureUsage: [.read], textureType: .texture2DArray, mipmapLevel: 2)
        descriptor.arrayLength = 2
        let proxy = Texture2DProxy(source: Texture2D(descriptor: descriptor))
        let pixel = Image(width: 1, height: 1, color: .red)
        #expect(throws: Never.self) { try proxy.uploadSubresource(.init(image: pixel, mipLevel: 1, slice: 1)) }
        descriptor.width = 4; descriptor.height = 4; descriptor.mipmapLevel = 3; descriptor.arrayLength = 3
        proxy.replaceSource(with: Texture2D(descriptor: descriptor))
        #expect(throws: Never.self) { try proxy.uploadSubresource(.init(image: pixel, mipLevel: 2, slice: 2)) }
        #expect(throws: (any Error).self) { try proxy.uploadSubresource(.init(image: pixel, mipLevel: 3, slice: 2)) }
        #expect(throws: (any Error).self) { try proxy.uploadSubresource(.init(image: pixel, mipLevel: 2, slice: 3)) }
        #expect(throws: (any Error).self) { try proxy.uploadSubresource(.init(image: Image(width: 2, height: 2, color: .red), mipLevel: 2, slice: 0)) }
    }

    @Test
    func keepsIdentityWhileReplacingBackingTexture() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }

        let first = RenderTexture(size: SizeInt(width: 16, height: 16), scaleFactor: 1, format: .bgra8)
        let second = RenderTexture(size: SizeInt(width: 16, height: 16), scaleFactor: 1, format: .bgra8)
        let proxy = Texture2DProxy(source: first)
        let identity = ObjectIdentifier(proxy)
        let firstBacking = ObjectIdentifier(proxy.gpuTexture)

        proxy.replaceSource(with: second)

        #expect(ObjectIdentifier(proxy) == identity)
        #expect(ObjectIdentifier(proxy.gpuTexture) != firstBacking)
        #expect(proxy.size == second.size)
    }

    @Test
    func replacingWithProxyFlattensBackingSource() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }

        let source = RenderTexture(size: SizeInt(width: 16, height: 16), scaleFactor: 1, format: .bgra8)
        let firstProxy = Texture2DProxy(source: source)
        let secondProxy = Texture2DProxy(source: firstProxy)

        firstProxy.replaceSource(with: firstProxy)
        firstProxy.replaceSource(with: secondProxy)

        #expect(ObjectIdentifier(firstProxy.gpuTexture) == ObjectIdentifier(source.gpuTexture))
    }
}
