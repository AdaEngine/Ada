@testable import AdaRender
import Foundation
import Testing

@Suite("Shader graph instances")
struct ShaderGraphMaterialTests {
    @Test func aNewMaterialReadsTheSavedGraphRatherThanAnOlderAsset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphReload-\(UUID().uuidString).shadergraph")
        defer { try? FileManager.default.removeItem(at: url) }
        var graph = try #require(source().graph)
        try JSONEncoder().encode(graph).write(to: url)
        let first = try ShaderGraphMaterial(source: .init(path: url.path))
        graph.nodes[0].value = [0, 1, 0, 1]
        try JSONEncoder().encode(graph).write(to: url)
        let reopened = try ShaderGraphMaterial(source: .init(path: url.path))
        #expect(first.value(for: "tint") == [1, 1, 1, 1])
        #expect(reopened.value(for: "tint") == [0, 1, 0, 1])
    }

    @Test func graphRenderSettingsAreEffectiveWithoutChangingLegacyMaterialState() throws {
        var source = source()
        source.graph?.target = .pbrSurface
        source.graph?.nodes[1].inputs = ["baseColor": .init("color")]
        source.graph?.renderSettings.mode = .mask
        source.graph?.renderSettings.alphaCutoff = 0.3
        source.graph?.renderSettings.doubleSided = true
        let material = PBRMaterial()
        material.alphaMode = .blend
        material.graphMaterial = try ShaderGraphMaterial(source: source)
        #expect(material.effectiveAlphaMode == .mask)
        #expect(material.effectiveAlphaCutoff == 0.3)
        #expect(material.effectiveDoubleSided)
        material.graphMaterial = nil
        #expect(material.effectiveAlphaMode == .blend)
        #expect(!material.effectiveDoubleSided)
        source.graph?.renderSettings.alphaCutoff = .nan
        #expect(throws: ShaderGraphDiagnostic(code: .invalidLiteral, nodeID: "output", port: "alphaCutoff")) {
            try ShaderGraphMaterial(source: source)
        }
    }

    private func source() -> ShaderGraphMaterialSource {
        .init(graph: ShaderGraph(target: .sprite, output: "output", nodes: [
            .init(id: "color", operation: .parameter, type: .color, value: [1, 1, 1, 1], reference: "tint"),
            .init(id: "output", operation: .output, inputs: ["color": .init("color")])
        ]))
    }

    @Test func instancesHaveIndependentValuesAndRoundTrip() throws {
        let first = try ShaderGraphMaterial(source: source())
        let second = try ShaderGraphMaterial(source: source())
        #expect(first.program.format == .wgsl)
        try first.setValue([0, 1, 0, 1], for: "tint")
        #expect(first.value(for: "tint") == [0, 1, 0, 1])
        #expect(second.value(for: "tint") == [1, 1, 1, 1])
        #expect(first.program.source == second.program.source)
        let copy = try JSONDecoder().decode(ShaderGraphMaterial.self, from: JSONEncoder().encode(first))
        #expect(copy.descriptor == first.descriptor)
        try copy.setValue([0, 0, 1, 1], for: "tint")
        #expect(copy.value(for: "tint") != first.value(for: "tint"))
        #expect(throws: ShaderGraphDiagnostic(code: .invalidLiteral, nodeID: "tint")) { try first.setValue([.nan], for: "tint") }
        #expect(throws: ShaderGraphDiagnostic(code: .invalidReference, nodeID: "missing")) { try first.setValue([1], for: "missing") }
    }

    @Test func changedValuesPreservePreviouslyPreparedGPUBytes() async throws {
        let device = HeadlessRenderBackend().renderDevice
        let material = try ShaderGraphMaterial(source: source())
        let before = material.resourceSet(device: device)
        guard case let .uniformBuffer(old, _) = before.bindings[0].resource else { Issue.record("Missing graph uniform buffer"); return }
        let original = try await old.readData()
        let reused = material.resourceSet(device: device)
        guard case let .uniformBuffer(same, _) = reused.bindings[0].resource else { Issue.record("Missing reused buffer"); return }
        #expect(old === same)
        try material.setValue([0, 1, 0, 1], for: "tint")
        let changed = material.resourceSet(device: device)
        guard case let .uniformBuffer(new, _) = changed.bindings[0].resource else { Issue.record("Missing updated buffer"); return }
        #expect(new !== old)
        #expect(try await old.readData() == original)
        #expect(try await new.readData() != original)
        #expect(new.length == 32)
    }
}
