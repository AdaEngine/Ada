#version 450 core
#pragma stage : vert
#ifdef ADA_MORPH
#extension GL_EXT_samplerless_texture_functions : require
#endif
#include <AdaEngine/View.glsl>
#include <AdaEngine/Morph.glsl>
layout (binding = 14) uniform Skinning3DUniform { mat4 u_Joints[256]; };
layout (binding = 24) uniform PreviousSkinning3DUniform { mat4 u_PreviousJoints[256]; };
layout (binding = 23) uniform Temporal3DUniform {
    mat4 u_CurrentViewProjection;
    mat4 u_PreviousViewProjection;
    mat4 u_InverseJitteredProjection;
    mat4 u_CurrentToPreviousView;
    vec4 u_Parameters;
};
layout (location = 0) in vec3 a_Position;
layout (location = 2) in vec2 a_UV;
layout (location = 3) in vec4 a_VertexColor;
layout (location = 5) in vec4 a_Model0;
layout (location = 6) in vec4 a_Model1;
layout (location = 7) in vec4 a_Model2;
layout (location = 8) in vec4 a_Model3;
layout (location = 9) in vec4 a_Color;
layout (location = 12) in vec4 a_ShadowFlags;
layout (location = 13) in vec4 a_Joints;
layout (location = 14) in vec4 a_Weights;
layout (location = 15) in vec2 a_UV1;
// Reuse normal/tangent/material/texture-flag locations to fit WebGPU's 16 attributes.
layout (location = 1) in vec4 a_PreviousModel0;
layout (location = 4) in vec4 a_PreviousModel1;
layout (location = 10) in vec4 a_PreviousModel2;
layout (location = 11) in vec4 a_PreviousModel3;
layout (location = 0) out vec4 v_CurrentClip;
layout (location = 1) out vec4 v_PreviousClip;
layout (location = 2) out vec2 v_UV;
layout (location = 3) out vec2 v_UV1;
layout (location = 4) out vec4 v_ColorFlags;
layout (location = 5) out float v_Fade;
layout (location = 6) flat out float v_ModelOrientation;
[[main]]
void motion_vertex() {
    mat4 skin = mat4(1.0), previousSkin = mat4(1.0);
    int jointBase = int(max(0.0, -a_ShadowFlags.y));
    if (a_Joints.x >= 0.0) {
        skin = u_Joints[jointBase + int(a_Joints.x)] * a_Weights.x + u_Joints[jointBase + int(a_Joints.y)] * a_Weights.y
             + u_Joints[jointBase + int(a_Joints.z)] * a_Weights.z + u_Joints[jointBase + int(a_Joints.w)] * a_Weights.w;
        previousSkin = u_PreviousJoints[jointBase + int(a_Joints.x)] * a_Weights.x + u_PreviousJoints[jointBase + int(a_Joints.y)] * a_Weights.y
             + u_PreviousJoints[jointBase + int(a_Joints.z)] * a_Weights.z + u_PreviousJoints[jointBase + int(a_Joints.w)] * a_Weights.w;
    }
    vec3 localPosition = a_Position;
    vec3 previousLocalPosition = a_Position;
#ifdef ADA_MORPH
    applyMorphPosition(localPosition);
    previousLocalPosition = previousMorphedPosition(a_Position);
#endif
    mat4 model = mat4(a_Model0, a_Model1, a_Model2, a_Model3) * skin;
    v_ModelOrientation = determinant(mat3(model)) < 0.0 ? -1.0 : 1.0;
    vec4 world = model * vec4(localPosition, 1.0);
    vec4 previousWorld = mat4(a_PreviousModel0, a_PreviousModel1, a_PreviousModel2, a_PreviousModel3) * previousSkin * vec4(previousLocalPosition, 1.0);
    v_CurrentClip = u_CurrentViewProjection * world;
    v_PreviousClip = u_Parameters.z > 0.5 ? v_CurrentClip : u_PreviousViewProjection * previousWorld;
    gl_Position = u_ViewProjection * world;
    v_UV = a_UV; v_UV1 = a_UV1;
    v_ColorFlags = vec4(a_Color.a * a_VertexColor.a, 0.0, max(0.0, a_ShadowFlags.y), 0.0);
    v_Fade = a_ShadowFlags.w;
}
#version 450 core
#pragma stage : frag
layout (location = 0) in vec4 v_CurrentClip;
layout (location = 1) in vec4 v_PreviousClip;
layout (location = 2) in vec2 v_UV;
layout (location = 3) in vec2 v_UV1;
layout (location = 4) in vec4 v_ColorFlags;
layout (location = 5) in float v_Fade;
layout (location = 6) flat in float v_ModelOrientation;
layout (location = 0) out vec4 o_Motion;
layout (location = 1) out vec4 o_Reactive;
layout (binding = 4) uniform texture2D u_BaseColor;
layout (binding = 7) uniform sampler u_Sampler;
layout (binding = 15) uniform PBR3DUniform {
    vec4 u_EmissiveFactor; vec4 u_SurfaceProperties; vec4 u_SurfaceFlags; vec4 u_UVSets; vec4 u_Emission;
    vec4 u_Parallax;
    vec4 u_TextureTransforms[10];
    vec4 u_Dielectric;
};
#define ADA_GRAPH_SOURCE_MARKER 1
[[main]]
void motion_fragment() {
    bool frontFacing = v_ModelOrientation < 0.0 ? !gl_FrontFacing : gl_FrontFacing;
    if (u_SurfaceFlags.x < 0.5 && !frontFacing) { discard; }
    if (v_Fade > 0.0) {
        int x = int(mod(floor(gl_FragCoord.x), 4.0)), y = int(mod(floor(gl_FragCoord.y), 4.0));
        const float values[16] = float[](0.0,8.0,2.0,10.0,12.0,4.0,14.0,6.0,3.0,11.0,1.0,9.0,15.0,7.0,13.0,5.0);
        if ((values[y * 4 + x] + 0.5) / 16.0 < v_Fade) { discard; }
    }
    float alpha = v_ColorFlags.x;
    #ifdef ADA_SHADER_GRAPH
    if (u_SurfaceProperties.w > 0.5) {
        AdaGraphSurface graph = ada_graph_evaluate(v_UV);
        alpha *= graph.color.a * graph.alpha;
    }
    #else
    // Opaque white is bound when the material has no base-color texture.
    {
        vec2 uv = u_UVSets.x > 0.5 ? v_UV1 : v_UV;
        uv = vec2(dot(u_TextureTransforms[0].xy, uv), dot(u_TextureTransforms[0].zw, uv)) + u_TextureTransforms[1].xy;
        alpha *= texture(sampler2D(u_BaseColor, u_Sampler), uv).a;
    }
    #endif
    if (u_SurfaceProperties.w > 0.5 && u_SurfaceProperties.w < 1.5 && alpha < u_SurfaceProperties.z) { discard; }
    bool valid = v_CurrentClip.w > 0.00001 && v_PreviousClip.w > 0.00001;
    vec2 motion = valid ? (v_PreviousClip.xy / v_PreviousClip.w - v_CurrentClip.xy / v_CurrentClip.w) * vec2(0.5, -0.5) : vec2(0.0);
    o_Motion = vec4(motion, valid ? v_PreviousClip.z / v_PreviousClip.w : 1.0, valid ? 1.0 : 0.0);
    float reactive = u_SurfaceProperties.w > 1.5 ? clamp(alpha * 2.0, 0.0, 1.0) : 0.0;
    reactive = max(reactive, v_ColorFlags.z > 0.0 || !valid || v_Fade > 0.0 ? 1.0 : 0.0);
    o_Reactive = vec4(reactive);
}
