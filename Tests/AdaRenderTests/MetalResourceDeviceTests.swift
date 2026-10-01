#if canImport(Metal)
@testable import AdaRender
import Foundation
import Math
import Testing

@Suite("Metal resource device")
struct MetalResourceDeviceTests {
    @Test("Concurrent resource loads reuse one context-free Metal device and queue")
    func reusesDeviceForConcurrentUploads() async throws {
        let backend = MetalRenderBackend()
        let device = backend.createLocalRenderDevice()
        #expect(device !== backend.renderDevice)
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
            #expect(local === device)
            let readback = try #require(local.getImage(from: texture))
            #expect(readback.data == image.data)
        }
    }
}
#endif
