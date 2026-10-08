import Testing
@_spi(Internal) @testable import AdaRender
import Math

@Suite(.serialized)
struct Texture2DProxyTests {
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
