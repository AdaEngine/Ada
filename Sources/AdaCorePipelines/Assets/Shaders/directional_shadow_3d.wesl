import package::mesh_visibility::{surface, meshOrientation, isVisibleFace, isVisibleFade, baseColorAlpha};
@if(ADA_MORPH) import package::mesh_morph::morphPosition;

// Shader Graph materials (ADA_SHADER_GRAPH) receive the generated graph source at this marker line.
// ADA_GRAPH_SOURCE_MARKER

struct ShadowInput {
    @location(0) position: vec3f,
    @location(2) uv0: vec2f,
    @location(3) vertexColor: vec4f,
    @location(5) model0: vec4f,
    @location(6) model1: vec4f,
    @location(7) model2: vec4f,
    @location(8) model3: vec4f,
    @location(9) color: vec4f,
    @location(12) flags: vec4f,
    @location(13) joints: vec4f,
    @location(14) weights: vec4f,
    @location(15) uv1: vec2f,
    @if(ADA_MORPH) @builtin(vertex_index) vertexIndex: u32,
}

struct ShadowVertex {
    @builtin(position) position: vec4f,
    @location(0) uv0: vec2f,
    @location(1) uv1: vec2f,
    @location(2) alpha: f32,
    @location(3) tileBounds: vec4f,
    @location(4) fade: f32,
    @location(5) @interpolate(flat) orientation: f32,
}

struct ShadowView {
    viewProjection: mat4x4f,
    tileBounds: vec4f,
}

struct SkinningUniform {
    matrices: array<mat4x4f, 256>,
}

@group(0) @binding(2) var<uniform> shadowView: ShadowView;
@group(0) @binding(14) var<uniform> skinning: SkinningUniform;

fn skinTransform(input: ShadowInput) -> mat4x4f {
    if input.joints.x < 0.0 {
        return mat4x4f(vec4f(1, 0, 0, 0), vec4f(0, 1, 0, 0), vec4f(0, 0, 1, 0), vec4f(0, 0, 0, 1));
    }
    let jointBase = i32(max(0.0, -input.flags.y));
    return skinning.matrices[jointBase + i32(input.joints.x)] * input.weights.x
        + skinning.matrices[jointBase + i32(input.joints.y)] * input.weights.y
        + skinning.matrices[jointBase + i32(input.joints.z)] * input.weights.z
        + skinning.matrices[jointBase + i32(input.joints.w)] * input.weights.w;
}

@vertex
fn directional_shadow_3d_vertex(input: ShadowInput) -> ShadowVertex {
    var localPosition = input.position;
    @if(ADA_MORPH) localPosition = morphPosition(localPosition, input.vertexIndex, false);
    let model = mat4x4f(input.model0, input.model1, input.model2, input.model3) * skinTransform(input);
    let position = shadowView.viewProjection * model * vec4f(localPosition, 1.0);
    return ShadowVertex(position, input.uv0, input.uv1, input.color.a * input.vertexColor.a,
        shadowView.tileBounds, input.flags.w, meshOrientation(model));
}

@fragment
fn directional_shadow_3d_fragment(input: ShadowVertex, @builtin(front_facing) frontFacing: bool) -> @location(0) vec4f {
    let pixel = input.position.xy;
    if any(pixel < input.tileBounds.xy) || any(pixel >= input.tileBounds.zw)
        || !isVisibleFade(pixel, input.fade) || !isVisibleFace(frontFacing, input.orientation) {
        discard;
    }
    let mode = surface.surfaceProperties.w;
    if mode > 0.5 && mode < 1.5 {
        var alpha = 0.0;
        @if(ADA_SHADER_GRAPH) {
            let graph = ada_graph_evaluate(input.uv0);
            alpha = graph.color.a * graph.alpha * input.alpha;
        }
        @if(!ADA_SHADER_GRAPH) {
            alpha = baseColorAlpha(input.uv0, input.uv1) * input.alpha;
        }
        if alpha < surface.surfaceProperties.z {
            discard;
        }
    }
    return vec4f(input.position.z);
}
