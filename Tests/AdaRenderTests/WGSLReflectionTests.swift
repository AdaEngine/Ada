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

    @Test func uniformBufferSizesFollowTheWGSLUniformLayout() {
        let source = """
            struct View { projection: mat4x4f, viewProjection: mat4x4f, viewMatrix: mat4x4f, }
            struct Mesh { model: mat4x4<f32>, inverse: mat4x4<f32>, }
            struct Circle { fade: f32, thickness: f32, color: vec4f, }
            struct Padded { a: vec3f, b: f32, }
            struct Shifted { a: f32, b: vec3f, }
            struct Outer { inner: Circle, tint: vec2f, }
            struct Lights { count: u32, values: array<vec4f, 4>, }
            @group(0) @binding(0) var<uniform> circle: Circle;
            @group(0) @binding(1) var<uniform> padded: Padded;
            @group(0) @binding(2) var<uniform> view: View;
            @group(0) @binding(3) var<uniform> mesh: Mesh;
            @group(0) @binding(4) var<uniform> shifted: Shifted;
            @group(0) @binding(5) var<uniform> outer: Outer;
            @group(0) @binding(6) var<uniform> lights: Lights;
            @group(0) @binding(7) var<uniform> color: vec4f;
            @group(0) @binding(8) var<uniform> unknown: Missing;
            """
        let sizes = WGSLReflection.parse(from: source, stage: .fragment).shaderBuffers.mapValues(\.size)
        #expect(sizes["circle"] == 32)
        #expect(sizes["padded"] == 16)
        #expect(sizes["view"] == 192)
        #expect(sizes["mesh"] == 128)
        #expect(sizes["shifted"] == 32)
        #expect(sizes["outer"] == 48)
        #expect(sizes["lights"] == 80)
        #expect(sizes["color"] == 16)
        // A type that cannot be resolved keeps the previous behavior instead of guessing.
        #expect(sizes["unknown"] == 0)
    }

    @Test func uniformLayoutIgnoresCommentsAndFallsBackForUnsupportedMembers() {
        let source = """
            struct Commented {
                fade: f32, // thickness: f32
                /* block: vec4f, */ color: vec4f, // trailing: f32
            }
            struct Attributed { @size(32) a: f32, }
            struct Half { a: f16, b: vec3<f16>, }
            struct Nested { first: Commented, second: Commented, }
            @group(0) @binding(0) var<uniform> commented: Commented;
            @group(0) @binding(1) var<uniform> attributed: Attributed;
            @group(0) @binding(2) var<uniform> half: Half;
            @group(0) @binding(3) var<uniform> nested: Nested;
            """
        let sizes = WGSLReflection.parse(from: source, stage: .fragment).shaderBuffers.mapValues(\.size)
        #expect(sizes["commented"] == 32)
        #expect(sizes["attributed"] == 0)
        #expect(sizes["half"] == 16)
        #expect(sizes["nested"] == 64)
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
