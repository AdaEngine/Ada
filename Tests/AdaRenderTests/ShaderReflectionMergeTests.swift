@testable import AdaRender
import Testing

@Suite
struct ShaderReflectionMergeTests {
    @Test
    func sharedDescriptorBindingsRemainVisibleToBothStages() {
        func reflection(stage: ShaderStageFlags) -> ShaderReflectionData {
            var set = ShaderResource.DescriptorSet()
            let buffer = ShaderResource.ShaderBuffer(
                name: "View", size: 64, shaderStage: stage, binding: 1, resourceAccess: .read, members: [:]
            )
            set.uniformsBuffers[1] = buffer
            set.constantBuffers[2] = buffer
            set.sampledImages[3] = ShaderResource.ImageSampler(
                name: "Texture",
                binding: 3,
                textureType: .texture2D,
                descriptorSet: 0,
                arraySize: 1,
                shaderStage: stage,
                resourceAccess: .read
            )
            set.samplers[4] = ShaderResource.Sampler(name: "Sampler", binding: 4, shaderStage: stage)
            var result = ShaderReflectionData()
            result.descriptorSets = [set]
            return result
        }
        var merged = reflection(stage: .vertex)
        merged.merge(reflection(stage: .fragment))
        let stages: ShaderStageFlags = [.vertex, .fragment]
        #expect(merged.descriptorSets[0].uniformsBuffers[1]?.shaderStage == stages)
        #expect(merged.descriptorSets[0].constantBuffers[2]?.shaderStage == stages)
        #expect(merged.descriptorSets[0].sampledImages[3]?.shaderStage == stages)
        #expect(merged.descriptorSets[0].samplers[4]?.shaderStage == stages)
        merged.merge(reflection(stage: .vertex))
        #expect(merged.descriptorSets[0].uniformsBuffers[1]?.shaderStage == stages)
    }
}
