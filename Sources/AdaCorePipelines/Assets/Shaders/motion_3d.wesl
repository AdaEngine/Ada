import ada_engine::view::projectPosition;
import package::mesh_visibility::{surface, meshOrientation, isVisibleFace, isVisibleFade, baseColorAlpha};
@if(ADA_MORPH) import package::mesh_morph::morphPosition;

struct MotionInput {
    @location(0) position: vec3f,
    @location(1) previousModel0: vec4f,
    @location(2) uv0: vec2f,
    @location(3) vertexColor: vec4f,
    @location(4) previousModel1: vec4f,
    @location(5) model0: vec4f,
    @location(6) model1: vec4f,
    @location(7) model2: vec4f,
    @location(8) model3: vec4f,
    @location(9) color: vec4f,
    @location(10) previousModel2: vec4f,
    @location(11) previousModel3: vec4f,
    @location(12) flags: vec4f,
    @location(13) joints: vec4f,
    @location(14) weights: vec4f,
    @location(15) uv1: vec2f,
    @if(ADA_MORPH) @builtin(vertex_index) vertexIndex: u32,
}

struct MotionVertex {
    @builtin(position) position: vec4f,
    @location(0) currentClip: vec4f,
    @location(1) previousClip: vec4f,
    @location(2) uv0: vec2f,
    @location(3) uv1: vec2f,
    @location(4) colorFlags: vec4f,
    @location(5) fade: f32,
    @location(6) @interpolate(flat) orientation: f32,
}

struct MotionOutput {
    @location(0) motion: vec4f,
    @location(1) reactive: vec4f,
}

struct TemporalUniform {
    currentViewProjection: mat4x4f,
    previousViewProjection: mat4x4f,
    inverseJitteredProjection: mat4x4f,
    currentToPreviousView: mat4x4f,
    parameters: vec4f,
}

struct SkinningUniform {
    matrices: array<mat4x4f, 256>,
}

@group(0) @binding(14) var<uniform> skinning: SkinningUniform;
@group(0) @binding(23) var<uniform> temporal: TemporalUniform;
@group(0) @binding(24) var<uniform> previousSkinning: SkinningUniform;

@vertex
fn motion_vertex(input: MotionInput) -> MotionVertex {
    let identity = mat4x4f(vec4f(1, 0, 0, 0), vec4f(0, 1, 0, 0), vec4f(0, 0, 1, 0), vec4f(0, 0, 0, 1));
    var skin = identity;
    var previousSkin = identity;
    if input.joints.x >= 0.0 {
        let joints = vec4i(input.joints) + i32(max(0.0, -input.flags.y));
        let weights = input.weights;
        skin = skinning.matrices[joints.x] * weights.x + skinning.matrices[joints.y] * weights.y
            + skinning.matrices[joints.z] * weights.z + skinning.matrices[joints.w] * weights.w;
        previousSkin = previousSkinning.matrices[joints.x] * weights.x + previousSkinning.matrices[joints.y] * weights.y
            + previousSkinning.matrices[joints.z] * weights.z + previousSkinning.matrices[joints.w] * weights.w;
    }
    var localPosition = input.position;
    var previousLocalPosition = input.position;
    @if(ADA_MORPH) localPosition = morphPosition(input.position, input.vertexIndex, false);
    @if(ADA_MORPH) previousLocalPosition = morphPosition(input.position, input.vertexIndex, true);
    let model = mat4x4f(input.model0, input.model1, input.model2, input.model3) * skin;
    let previousModel = mat4x4f(input.previousModel0, input.previousModel1, input.previousModel2, input.previousModel3) * previousSkin;
    let world = model * vec4f(localPosition, 1.0);
    let previousWorld = previousModel * vec4f(previousLocalPosition, 1.0);
    let currentClip = temporal.currentViewProjection * world;
    var previousClip = currentClip;
    if temporal.parameters.z <= 0.5 {
        previousClip = temporal.previousViewProjection * previousWorld;
    }
    let colorFlags = vec4f(input.color.a * input.vertexColor.a, 0.0, max(0.0, input.flags.y), 0.0);
    return MotionVertex(projectPosition(world), currentClip, previousClip, input.uv0, input.uv1,
        colorFlags, input.flags.w, meshOrientation(model));
}

@fragment
fn motion_fragment(input: MotionVertex, @builtin(front_facing) frontFacing: bool) -> MotionOutput {
    if !isVisibleFace(frontFacing, input.orientation) || !isVisibleFade(input.position.xy, input.fade) {
        discard;
    }
    let mode = surface.surfaceProperties.w;
    let alpha = input.colorFlags.x * baseColorAlpha(input.uv0, input.uv1);
    if mode > 0.5 && mode < 1.5 && alpha < surface.surfaceProperties.z {
        discard;
    }
    let valid = input.currentClip.w > 0.00001 && input.previousClip.w > 0.00001;
    var velocity = vec2f(0.0);
    var previousDepth = 1.0;
    if valid {
        velocity = (input.previousClip.xy / input.previousClip.w - input.currentClip.xy / input.currentClip.w) * vec2f(0.5, -0.5);
        previousDepth = input.previousClip.z / input.previousClip.w;
    }
    let reactive = select(0.0, clamp(alpha * 2.0, 0.0, 1.0), mode > 1.5);
    let forceReactive = input.colorFlags.z > 0.0 || !valid || input.fade > 0.0;
    return MotionOutput(vec4f(velocity, previousDepth, select(0.0, 1.0, valid)), vec4f(max(reactive, select(0.0, 1.0, forceReactive))));
}
