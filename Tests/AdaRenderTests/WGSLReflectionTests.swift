@testable import AdaRender
import Testing

@Suite("Generated WGSL bindings")
struct WGSLReflectionTests {
    @Test(arguments: ["0", "0u", " 0u "])
    func recognizesTintUnsignedBindings(group: String) {
        let source = """
        @group(\(group)) @binding(2u) var<uniform> view: GlobalView;
        @group(\(group)) @binding(0u) var image: texture_2d<f32>;
        @group(\(group)) @binding(1u) var imageSampler: sampler;
        """
        let reflection = WGSLReflection.parse(from: source, stage: .fragment)
        #expect(reflection.descriptorSets.count == 1)
        #expect(reflection.shaderBuffers["view"]?.binding == 2)
        #expect(reflection.resources["image"]?.binding == 0)
        #expect(reflection.samplers["imageSampler"]?.binding == 1)
        #expect(reflection.descriptorSets.first?.uniformsBuffers[2]?.shaderStage == .fragment)
        #expect(reflection.descriptorSets.first?.sampledImages[0] != nil)
        #expect(reflection.descriptorSets.first?.samplers[1] != nil)
    }

    @Test func mergesSharedStageBindingsAndSparseSets() {
        let source = "@group(2u) @binding(4) var< uniform > view: GlobalView;"
        var reflection = WGSLReflection.parse(from: source, stage: .vertex)
        reflection.merge(WGSLReflection.parse(from: source, stage: .fragment))
        #expect(reflection.descriptorSets.count == 3)
        #expect(reflection.descriptorSets[0].uniformsBuffers.isEmpty)
        #expect(reflection.descriptorSets[2].uniformsBuffers[4]?.shaderStage == [.vertex, .fragment])
    }
}
