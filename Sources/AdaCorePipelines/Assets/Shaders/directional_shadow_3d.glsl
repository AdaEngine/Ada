#version 450 core
#pragma stage : vert

layout (location = 13) in vec4 a_JointIndices;
layout (location = 14) in vec4 a_JointWeights;
layout (binding = 14) uniform Skinning3DUniform {
    mat4 u_JointMatrices[128];
};

mat4 skinTransform() {
    if (a_JointIndices.x < 0.0) { return mat4(1.0); }
    return u_JointMatrices[int(a_JointIndices.x)] * a_JointWeights.x
        + u_JointMatrices[int(a_JointIndices.y)] * a_JointWeights.y
        + u_JointMatrices[int(a_JointIndices.z)] * a_JointWeights.z
        + u_JointMatrices[int(a_JointIndices.w)] * a_JointWeights.w;
}

layout (location = 0) in vec3 a_Position;
layout (location = 2) in vec2 a_TextureCoordinate;
layout (location = 15) in vec2 a_TextureCoordinate1;
layout (location = 3) in vec4 a_VertexColor;
layout (location = 9) in vec4 a_Color;
layout (location = 12) in vec4 a_ShadowFlags;
layout (location = 0) out vec2 v_UV0;
layout (location = 1) out vec2 v_UV1;
layout (location = 2) out float v_Alpha;
layout (location = 3) out vec4 v_TileBounds;
layout (location = 4) out float v_Fade;
layout (location = 5) in vec4 a_Model0;
layout (location = 6) in vec4 a_Model1;
layout (location = 7) in vec4 a_Model2;
layout (location = 8) in vec4 a_Model3;

layout (binding = 2) uniform DirectionalShadowViewUniform {
    mat4 u_ShadowViewProjection;
    vec4 u_TileBounds;
};

[[main]]
void directional_shadow_3d_vertex()
{
    mat4 model = mat4(a_Model0, a_Model1, a_Model2, a_Model3) * skinTransform();
    v_Fade = a_ShadowFlags.w;
    v_TileBounds = u_TileBounds;
    v_UV0 = a_TextureCoordinate;
    v_UV1 = a_TextureCoordinate1;
    v_Alpha = a_Color.a * a_VertexColor.a;
    gl_Position = u_ShadowViewProjection * model * vec4(a_Position, 1.0);
}

#version 450 core
#pragma stage : frag

layout (location = 0) out vec4 o_Depth;
layout (location = 0) in vec2 v_UV0;
layout (location = 1) in vec2 v_UV1;
layout (location = 2) in float v_Alpha;
layout (location = 3) in vec4 v_TileBounds;
layout (location = 4) in float v_Fade;
layout (binding = 4) uniform texture2D u_BaseColorTexture;
layout (binding = 7) uniform sampler u_BaseColorSampler;
layout (binding = 15) uniform PBR3DUniform {
    vec4 u_EmissiveFactor;
    vec4 u_SurfaceProperties;
    vec4 u_SurfaceFlags;
    vec4 u_UVSets;
    vec4 u_Emission;
};

[[main]]
void directional_shadow_3d_fragment()
{
    if (any(lessThan(gl_FragCoord.xy, v_TileBounds.xy)) || any(greaterThanEqual(gl_FragCoord.xy, v_TileBounds.zw))) { discard; }
    if (v_Fade > 0.0) {
        int x = int(mod(floor(gl_FragCoord.x), 4.0)), y = int(mod(floor(gl_FragCoord.y), 4.0));
        const float values[16] = float[](0.0,8.0,2.0,10.0,12.0,4.0,14.0,6.0,3.0,11.0,1.0,9.0,15.0,7.0,13.0,5.0);
        if ((values[y * 4 + x] + 0.5) / 16.0 < v_Fade) { discard; }
    }
    if (u_SurfaceFlags.x < 0.5 && !gl_FrontFacing) { discard; }
    if (u_SurfaceProperties.w > 0.5 && u_SurfaceProperties.w < 1.5) {
        vec2 uv = u_UVSets.x > 0.5 ? v_UV1 : v_UV0;
        float alpha = texture(sampler2D(u_BaseColorTexture, u_BaseColorSampler), uv).a * v_Alpha;
        if (alpha < u_SurfaceProperties.z) { discard; }
    }
    o_Depth = vec4(gl_FragCoord.z);
}
