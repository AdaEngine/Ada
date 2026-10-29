#version 450 core
#pragma stage : vert
#include <AdaEngine/View.glsl>
layout(location = 0) in vec4 a_CenterSize;
layout(location = 1) in vec4 a_Color;
layout(location = 2) in vec4 a_Parameters;
layout(location = 0) out vec2 v_UV;
layout(location = 1) out vec4 v_Color;
layout(location = 2) out vec4 v_Clip;
layout(location = 3) out vec3 v_Particle;
layout(location = 4) flat out float v_Style;
[[main]]
void particles_vertex() {
    const vec2 corners[6] = vec2[](vec2(-1,-1),vec2(1,-1),vec2(1,1),vec2(-1,-1),vec2(1,1),vec2(-1,1));
    vec2 corner = corners[gl_VertexIndex];
    float c = cos(a_Parameters.x), s = sin(a_Parameters.x);
    vec2 shaped = corner * vec2(a_Parameters.z, 1.0);
    vec2 rotated = vec2(c*shaped.x-s*shaped.y,s*shaped.x+c*shaped.y);
    vec3 position = a_CenterSize.xyz + vec3(rotated * a_CenterSize.w * 0.5,0.0);
    v_Clip = u_Projection * vec4(position,1.0);
    gl_Position = v_Clip;
    v_UV = corner;
    v_Color = a_Color;
    v_Particle = vec3(a_CenterSize.z,a_Parameters.y,a_Parameters.x);
    v_Style = a_Parameters.w;
}
#version 450 core
#pragma stage : frag
layout(location = 0) in vec2 v_UV;
layout(location = 1) in vec4 v_Color;
layout(location = 2) in vec4 v_Clip;
layout(location = 3) in vec3 v_Particle;
layout(location = 4) flat in float v_Style;
layout(location = 0) out vec4 o_Color;
layout(binding = 0) uniform texture2D u_Position;
layout(binding = 1) uniform sampler u_Sampler;
[[main]]
void particles_fragment() {
    float radius = dot(v_UV,v_UV);
    if (radius >= 1.0) { discard; }
    vec2 screenUV = v_Clip.xy / v_Clip.w * vec2(0.5,-0.5) + 0.5;
    vec3 scene = textureLod(sampler2D(u_Position,u_Sampler),screenUV,0.0).xyz;
    float sceneDepth = length(scene) < 0.0001 ? 100000.0 : scene.z;
    float intersection = clamp((sceneDepth-v_Particle.x)/v_Particle.y,0.0,1.0);
    float nearFade = smoothstep(0.05,0.3,v_Particle.x);
    // Smooth procedural lobes keep smoke soft and remove the need for a texture asset.
    float detail = v_Style > 0.5 ? 1.0 : 0.78 + 0.22*sin(v_UV.x*6.0+v_Particle.z)*cos(v_UV.y*5.0-v_Particle.z);
    float alpha = v_Color.a * (1.0-radius)*(1.0-radius) * detail * intersection * nearFade;
    o_Color = vec4(v_Color.rgb,alpha);
}
