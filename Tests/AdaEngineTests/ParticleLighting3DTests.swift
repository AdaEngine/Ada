import AdaECS
import Math
import Testing

@testable import AdaCorePipelines

@Suite("3D particle light packing")
struct ParticleLighting3DTests {
    @Test func cameraSpaceLightsAreBoundedAndMissingAtlasNeverEnablesShadowSampling() {
        let world = World()
        var entry = LocalShadow3DViews.Entry()
        for index in 0..<12 {
            entry.lights.append(.init(entity: world.spawn().id, kind: .point, position: [Float(index), 2, 3], intensity: Float(index + 1), range: 4))
        }
        entry.allocator.select(entry.lights, cameraPosition: .zero, budget: 4)
        var data = [Vector4](repeating: .zero, count: ParticleLighting3D.vectorCount)
        let view = Transform3D(translation: [-1, 0, 0])
        ParticleLighting3D.pack(ExtractedLighting3D(), view: view, shadows: entry, into: &data)
        #expect(data.count == 39 && data[0].w == 8)
        #expect(data[3] == Vector4(-1, 2, 3, 4))
        #expect(data[3 + 7 * 4] == Vector4(6, 2, 3, 4))
        #expect((0..<8).allSatisfy { data[3 + $0 * 4 + 3].w == -1 })
        #expect(data[38] == Vector4(1, 0, 0, 1))
        ParticleLighting3D.pack(ExtractedLighting3D(), view: .identity, shadows: nil, into: &data)
        #expect(data[0].w == 0, "Stale entries beyond the light count must never be read after a flash expires.")
        #expect(data[1].w == 3.2, "The unauthored default sun must match the opaque pass.")
        var authored = ExtractedLighting3D()
        authored.hasAuthoredLights = true
        ParticleLighting3D.pack(authored, view: .identity, shadows: nil, into: &data)
        #expect(data[1].w == 0, "A night scene with authored lamps must not invent a sun.")
    }
}
