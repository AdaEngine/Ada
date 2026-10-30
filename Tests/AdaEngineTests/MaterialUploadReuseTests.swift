@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

@Suite
@MainActor
struct MaterialUploadReuseTests {
    @Test("Cross-frame material caching observes edits and releases unused owners")
    func cachedMaterialExpiresAfterAnUnusedFrame() async throws {
        let device = HeadlessRenderBackend().renderDevice
        var uniforms = PBR3DUniforms()
        let original = PBRMaterial()
        uniforms.beginFrame()
        uniforms.write(material: original, descriptor: VertexDescriptor(), device: device)
        let initial = try #require(uniforms.buffer(for: original))
        for _ in 0..<8 {
            uniforms.beginFrame()
            #expect(uniforms.buffer(for: original) == nil)
            uniforms.write(material: original, descriptor: VertexDescriptor(), device: device)
            #expect(uniforms.buffer(for: original) === initial)
        }
        original.normalScale = 3
        uniforms.beginFrame()
        uniforms.write(material: original, descriptor: VertexDescriptor(), device: device)
        let edited = try #require(uniforms.buffer(for: original))
        #expect(edited !== initial)
        #expect(unsafe edited.contents().load(as: PBR3DUniform.self).properties.x == 3)
        // The retained `original` above tests identity; use a second owner to
        // verify that the cache cannot keep removed scene materials alive.
        var transient: PBRMaterial? = PBRMaterial()
        weak var transientOwner = transient
        uniforms.write(material: try #require(transient), descriptor: VertexDescriptor(), device: device)
        transient = nil
        #expect(transientOwner != nil)
        uniforms.beginFrame()
        uniforms.beginFrame()
        #expect(transientOwner == nil)
    }

    @Test
    func everySharedUniformFieldInvalidatesTheMaterialSnapshot() throws {
        let device = HeadlessRenderBackend().renderDevice
        let texture = Texture2D(
            gpuTexture: device.createTexture(from: .init(textureUsage: .read, textureType: .texture2D)),
            sampler: device.createSampler(from: SamplerDescriptor()), size: [1, 1]
        )
        let edits: [(PBRMaterial) -> Void] = [
            { $0.baseColorFactor.w = 0.4 },
            { $0.emissiveFactor = [0.2, 0.3, 0.4] },
            { $0.occlusionTexture = texture },
            { $0.occlusionStrength = 0.2 },
            { $0.normalScale = 2 },
            { $0.alphaMode = .mask },
            { $0.alphaCutoff = 0.1 },
            { $0.doubleSided = true },
            { $0.textureCoordinates[3] = 1 },
        ]
        var uniforms = PBR3DUniforms()
        for edit in edits {
            uniforms.beginFrame()
            let material = PBRMaterial()
            uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
            let original = try #require(uniforms.buffer(for: material))
            edit(material)
            uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
            let edited = try #require(uniforms.buffer(for: material))
            #expect(edited !== original)
            uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
            #expect(uniforms.buffer(for: material) === edited)
        }
    }

    @Test
    func staticInstancesReuseEachInFlightUploadAndRefreshAfterEditsAndGrowth() async throws {
        let device = HeadlessRenderBackend().renderDevice
        var instances = Opaque3DInstanceBuffers()
        let count = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        let first = Flat3DInstanceData(modelMatrix: .identity, color: [1, 0, 0, 1], material: .zero)
        let second = Flat3DInstanceData(modelMatrix: Transform3D(translation: [3, 0, 0]), color: [0, 1, 0, 1], material: .zero)
        for _ in 0..<count {
            instances.beginFrame()
            _ = instances.append(first)
            _ = instances.append(second)
            instances.write(to: device)
            let buffer = try #require(instances.currentBuffer?.buffer)
            unsafe buffer.contents().initializeMemory(as: UInt8.self, repeating: 0xa5, count: buffer.length)
        }
        for _ in 0..<count {
            instances.beginFrame()
            _ = instances.append(first)
            _ = instances.append(second)
            instances.write(to: device)
            let buffer = try #require(instances.currentBuffer?.buffer)
            #expect(try await buffer.readData() == Data(repeating: 0xa5, count: buffer.length))
        }
        for _ in 0..<count {
            instances.beginFrame()
            _ = instances.append(second)
            _ = instances.append(first)
            _ = instances.append(second)
            instances.write(to: device)
            let buffer = try #require(instances.currentBuffer?.buffer)
            let values = try await buffer.readData()
            values.withUnsafeBytes { bytes in
                #expect(unsafe bytes.loadUnaligned(as: Flat3DInstanceData.self) == second)
                #expect(unsafe bytes.loadUnaligned(fromByteOffset: MemoryLayout<Flat3DInstanceData>.stride, as: Flat3DInstanceData.self) == first)
                #expect(unsafe bytes.loadUnaligned(fromByteOffset: 2 * MemoryLayout<Flat3DInstanceData>.stride, as: Flat3DInstanceData.self) == second)
            }
        }
        instances.beginFrame()
        instances.write(to: device)
        instances.beginFrame()
        _ = instances.append(first)
        instances.write(to: device)
        let shrunk = try #require(instances.currentBuffer?.buffer)
        let value = unsafe shrunk.contents().load(as: Flat3DInstanceData.self)
        #expect(value == first)
    }

    @Test
    func unchangedMaterialAvoidsUploadsAndMutationPreservesInFlightBuffer() async throws {
        let device = HeadlessRenderBackend().renderDevice
        var uniforms = PBR3DUniforms()
        let material = PBRMaterial()
        uniforms.beginFrame()
        uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
        let buffer = try #require(uniforms.buffer(for: material))
        let marker = Data(repeating: 0xa5, count: buffer.length)
        unsafe buffer.contents().initializeMemory(as: UInt8.self, repeating: 0xa5, count: buffer.length)
        uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
        #expect(try await buffer.readData() == marker)
        material.normalScale = 2
        uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
        let edited = try #require(uniforms.buffer(for: material))
        #expect(edited !== buffer)
        #expect(try await buffer.readData() == marker)
        let value = unsafe edited.contents().load(as: PBR3DUniform.self)
        #expect(value.properties.x == 2)
        // Subsequent frames reuse the edited value without rewriting in-flight data.
        for _ in 0..<max(1, unsafe RenderEngine.configurations.maxFramesInFlight) {
            uniforms.beginFrame()
            uniforms.write(material: material, descriptor: VertexDescriptor(), device: device)
            let current = try #require(uniforms.buffer(for: material))
            let snapshot = unsafe current.contents().load(as: PBR3DUniform.self)
            #expect(snapshot.properties.x == 2)
        }
    }
}
