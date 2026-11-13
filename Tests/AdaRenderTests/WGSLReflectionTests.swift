@testable import AdaRender
import Testing

@Suite("Generated WGSL bindings")
struct WGSLReflectionTests {
    @Test func autoLayoutFollowsOnlyEntryPointReachableHelpers() {
        let source = """
            @group(0) @binding(0) var<uniform> used: vec4f;
            @group(0) @binding(1) var<uniform> dead: vec4f;
            @group(1) @binding(2) var<uniform> other: vec4f;
            fn helper() -> vec4f { return used; }
            fn deadHelper() -> vec4f { return dead; }
            @fragment fn main() -> @location(0) vec4f { /* deadHelper(); */ return helper(); }
            @fragment fn second() -> @location(0) vec4f { return other; }
            """
        let main = WGSLReflection.parse(from: source, stage: .fragment, entryPoint: "main")
        #expect(Set(main.shaderBuffers.keys) == ["used"])
        #expect(main.descriptorSets.count == 1)
        let second = WGSLReflection.parse(from: source, stage: .fragment, entryPoint: "second")
        #expect(Set(second.shaderBuffers.keys) == ["other"])
        #expect(WGSLReflection.parse(from: source, stage: .fragment).shaderBuffers.count == 3)
    }

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

    @Test func preservesSampledTextureViewDimensionsForBrowserLayouts() {
        let source = """
            @group(0) @binding(0) var color: texture_2d<f32>;
            @group(0) @binding(1) var terrain: texture_2d_array<f32>;
            @group(0) @binding(2) var sky: texture_cube<f32>;
            @group(0) @binding(3) var volume: texture_3d<f32>;
            @group(0) @binding(4) var depth: texture_depth_2d;
            @group(0) @binding(5) var depthLayers: texture_depth_2d_array;
            """
        let reflection = WGSLReflection.parse(from: source, stage: .fragment)
        let images = reflection.descriptorSets.first?.sampledImages
        #expect(images?[0]?.textureType == .texture2D)
        #expect(images?[1]?.textureType == .texture2DArray)
        #expect(images?[2]?.textureType == .textureCube)
        #expect(images?[3]?.textureType == .texture3D)
        #expect(images?[0]?.isDepth == nil)
        #expect(images?[4]?.isDepth == true)
        #expect(images?[5]?.isDepth == true)
        #expect(images?[5]?.textureType == .texture2DArray)
    }
}
