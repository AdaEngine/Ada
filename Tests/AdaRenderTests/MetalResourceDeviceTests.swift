#if os(macOS) && SAGA_METAL_NATIVE_PASS
@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@Suite("SAGA Metal resource devices")
struct SAGAMetalResourceDeviceTests {
    @Test("Concurrent local uploads are visible to the SAGA render device")
    func concurrentUploadsAreVisibleToTheRenderer() async throws {
        let backend = try SAGAMetalRenderBackend()
        let renderer = try #require(backend.renderDevice as? SAGARenderDevice)
        let image = Image(width: 2, height: 1, data: Data([255, 0, 0, 255, 0, 255, 0, 255]))
        let uploads = await withTaskGroup(of: (RenderDevice, Texture2D).self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let local = backend.createLocalRenderDevice()
                    let descriptor = TextureDescriptor(
                        width: image.width,
                        height: image.height,
                        pixelFormat: .rgba8,
                        textureUsage: [.read],
                        textureType: .texture2D,
                        image: image,
                        samplerDescription: image.samplerDescription
                    )
                    let texture = Texture2D(
                        gpuTexture: local.createTexture(from: descriptor),
                        sampler: local.createSampler(from: image.samplerDescription),
                        size: SizeInt(width: image.width, height: image.height)
                    )
                    return (local, texture)
                }
            }
            var uploads: [(RenderDevice, Texture2D)] = []
            for await upload in group { uploads.append(upload) }
            return uploads
        }
        #expect(uploads.count == 32)
        for (local, texture) in uploads {
            let uploadDevice = try #require(local as? SAGARenderDevice)
            #expect(uploadDevice !== renderer)
            #expect(uploadDevice.context === renderer.context)
            let readback = try #require(try await renderer.readImage(from: texture))
            #expect(readback.data == image.data)
        }
    }
}
#endif
