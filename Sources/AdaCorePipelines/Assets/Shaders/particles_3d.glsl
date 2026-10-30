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
layout(location = 5) out vec3 v_ViewPosition;
layout(location = 6) flat out vec4 v_CenterSize;
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
    v_ViewPosition = position;
    v_CenterSize = a_CenterSize;
}
#version 450 core
#pragma stage : frag
layout(location = 0) in vec2 v_UV;
layout(location = 1) in vec4 v_Color;
layout(location = 2) in vec4 v_Clip;
layout(location = 3) in vec3 v_Particle;
layout(location = 4) flat in float v_Style;
layout(location = 5) in vec3 v_ViewPosition;
layout(location = 6) flat in vec4 v_CenterSize;
layout(location = 0) out vec4 o_Color;
#ifdef PARTICLE_INDIRECT
layout(location = 1) out vec4 o_Indirect;
#endif
#ifdef PARTICLE_REFLECTION_RESPONSE
layout(location = 2) out vec4 o_ReflectionResponse;
#endif
layout(binding = 0) uniform texture2D u_Position;
layout(binding = 1) uniform sampler u_Sampler;
layout(binding = 6) uniform texture2D u_ParticleShadows;
layout(binding = 7) uniform sampler u_ShadowSampler;
struct SmokeLight {
    vec4 positionRange;
    vec4 radianceIntensity;
    vec4 directionOuter;
    vec4 innerShadow;
};
layout(binding = 4) uniform ParticleLighting {
    vec4 u_AmbientCount;
    vec4 u_SunDirectionIntensity;
    vec4 u_SunRadiance;
    SmokeLight u_SmokeLights[8];
    mat4 u_ParticleInverseView;
};
layout(binding = 5) uniform ParticleShadowMatrices {
    mat4 u_ParticleShadowMatrices[24];
    vec4 u_ParticleAtlas;
};

int smokePointFace(vec3 ray) {
    vec3 a = abs(ray);
    if (a.x >= a.y && a.x >= a.z) { return ray.x >= 0.0 ? 0 : 1; }
    if (a.y >= a.z) { return ray.y >= 0.0 ? 2 : 3; }
    return ray.z >= 0.0 ? 4 : 5;
}

float smokeShadow(SmokeLight light, vec3 position) {
    int slot = int(light.innerShadow.w);
    if (slot < 0 || slot >= 4) { return 1.0; }
    vec3 worldRay = mat3(u_ParticleInverseView) * (position-light.positionRange.xyz);
    int face = light.directionOuter.w < 0.0 ? smokePointFace(worldRay) : 0;
    vec3 worldPosition = (u_ParticleInverseView * vec4(position,1.0)).xyz;
    vec4 clip = u_ParticleShadowMatrices[slot*6+face] * vec4(worldPosition,1.0);
    if (clip.w <= 0.0) { return 1.0; }
    vec3 ndc = clip.xyz/clip.w;
    if (ndc.z < 0.0 || ndc.z > 1.0 || any(greaterThan(abs(ndc.xy),vec2(1.0)))) { return 1.0; }
    vec2 origin = vec2(float(face),float(slot))*u_ParticleAtlas.z;
    vec2 lo = (origin+0.5)*u_ParticleAtlas.xy;
    vec2 hi = (origin+u_ParticleAtlas.z-0.5)*u_ParticleAtlas.xy;
    vec2 uv = (origin+(ndc.xy*vec2(0.5,-0.5)+0.5)*u_ParticleAtlas.z)*u_ParticleAtlas.xy;
    float visibility = 0.0;
    for (int y=0;y<2;++y) { for (int x=0;x<2;++x) {
        vec2 offset = (vec2(float(x),float(y))-0.5)*u_ParticleAtlas.xy;
        float depth = textureLod(sampler2D(u_ParticleShadows,u_ShadowSampler),clamp(uv+offset,lo,hi),0.0).r;
        visibility += ndc.z-light.innerShadow.y <= depth ? 1.0 : 0.0;
    } }
    return visibility*0.25;
}

// Three fixed density layers approximate a small cloud. Its shape changes continuously
// with the particle's phase; no texture fetches, per-puff materials or simulation entities.
float smokeDensity(vec2 uv, float chord) {
    float density = 0.0;
    for (int layer=0;layer<3;++layer) {
        vec3 p = vec3(uv,(float(layer)-1.0)*chord*0.66);
        vec3 warped = p+0.14*sin(p.yzx*5.1+vec3(v_Particle.z,2.1,4.3));
        float body = max(0.0,1.0-dot(warped,warped));
        float lobe = 0.62+0.38*sin(warped.x*7.0+v_Particle.z)*sin(warped.y*6.0-v_Particle.z)*cos(warped.z*6.0);
        density += body*body*lobe;
    }
    return density*chord;
}

vec3 smokeLighting(vec3 normal, vec3 position) {
    vec3 result = u_AmbientCount.rgb;
    vec3 sun = u_SunDirectionIntensity.xyz;
    result += max(u_SunRadiance.rgb,vec3(0.0))*max(0.0,u_SunDirectionIntensity.w)*0.12*(0.5+0.5*dot(normal,sun));
    for (int i=0;i<8;++i) {
        if (i>=int(u_AmbientCount.w)) { break; }
        SmokeLight light = u_SmokeLights[i];
        vec3 delta = light.positionRange.xyz-position;
        float distance = length(delta), range = light.positionRange.w;
        if (distance>=range || range<=0.0) { continue; }
        vec3 direction = delta/max(distance,0.0001);
        float ratio = distance/range;
        float cutoff = max(0.0,1.0-ratio*ratio*ratio*ratio);
        float attenuation = cutoff*cutoff/max(distance*distance,0.04);
        if (light.directionOuter.w>=0.0) {
            attenuation *= smoothstep(light.directionOuter.w,light.innerShadow.x,dot(normalize(light.directionOuter.xyz),-direction));
        }
        if (attenuation<=0.0) { continue; }
        float wrap = 0.4+0.6*max(0.0,dot(normal,direction));
        float forwardScatter = pow(max(0.0,dot(-direction,normalize(-position))),4.0);
        result += max(light.radianceIntensity.rgb,vec3(0.0))*max(0.0,light.radianceIntensity.w)*attenuation
            *0.08*(wrap+forwardScatter)*smokeShadow(light,position);
    }
    return result;
}

void writeCoverage(float alpha) {
    // Reflections are composed later. Their opaque contribution must obey the same
    // transmittance as sceneColor or it would shine through a dense cloud.
#ifdef PARTICLE_INDIRECT
    o_Indirect = vec4(0.0,0.0,0.0,alpha);
#endif
#ifdef PARTICLE_REFLECTION_RESPONSE
    o_ReflectionResponse = vec4(0.0,0.0,0.0,alpha);
#endif
}
[[main]]
void particles_fragment() {
    float radius = dot(v_UV,v_UV);
    if (radius >= 1.0) { discard; }
    vec2 screenUV = v_Clip.xy / v_Clip.w * vec2(0.5,-0.5) + 0.5;
    vec3 scene = textureLod(sampler2D(u_Position,u_Sampler),screenUV,0.0).xyz;
    float sceneDepth = length(scene) < 0.0001 ? 100000.0 : scene.z;
    float intersection = clamp((sceneDepth-v_Particle.x)/v_Particle.y,0.0,1.0);
    float nearFade = smoothstep(0.05,0.3,v_Particle.x);
    if (v_Style > 2.5) {
        float chord = sqrt(max(0.0,1.0-radius));
        float density = smokeDensity(v_UV,chord);
        float alpha = (1.0-exp(-density*v_Color.a*2.0))*intersection*nearFade;
        if (alpha<0.0001) { discard; }
        // A rounded view-space normal gives each density lobe a lit and an extinct side.
        vec3 normal = normalize(vec3((v_ViewPosition.xy-v_CenterSize.xy)/max(v_CenterSize.w*0.5,0.0001),-chord));
        vec3 position = v_ViewPosition+vec3(0.0,0.0,-chord*v_CenterSize.w*0.25);
        o_Color = vec4(v_Color.rgb*smokeLighting(normal,position),alpha);
        writeCoverage(alpha);
        return;
    }
    // Smooth procedural lobes keep smoke soft and remove the need for a texture asset.
    float detail = v_Style > 0.5 ? 1.0 : 0.78 + 0.22*sin(v_UV.x*6.0+v_Particle.z)*cos(v_UV.y*5.0-v_Particle.z);
    float alpha = v_Color.a * (1.0-radius)*(1.0-radius) * detail * intersection * nearFade;
    o_Color = vec4(v_Color.rgb,alpha);
    writeCoverage(alpha);
}
