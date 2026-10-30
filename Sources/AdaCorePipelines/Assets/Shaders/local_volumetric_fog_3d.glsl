#version 450 core
#pragma stage : vert
layout (location = 0) out vec2 v_UV;
[[main]]
void volumetric_fog_vertex() {
    vec2 uv = vec2(float(gl_VertexIndex >> 1u), float(gl_VertexIndex & 1u)) * 2.0;
    gl_Position = vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_UV = uv;
}

#version 450 core
#pragma stage : frag
layout (location = 0) in vec2 v_UV;
layout (location = 0) out vec4 o_Color;
layout (binding = 0) uniform texture2D u_ViewPositionMetallic;
layout (binding = 1) uniform texture2D u_DirectionalShadowTexture;
layout (binding = 2) uniform sampler u_Nearest;
layout (binding = 4) uniform VolumetricFog3DUniform {
    mat4 u_InverseView;
    mat4 u_InverseProjection;
    mat4 u_ShadowViewProjection0;
    mat4 u_ShadowViewProjection1;
    mat4 u_ShadowViewProjection2;
    vec4 u_CascadeSplits; // xyz far view depth of each cascade, w cascade count
    vec4 u_ShadowAtlas;   // xy shadow texel size, z constant bias, w 1 when shadows are enabled
    vec4 u_SunDirection;  // xyz world direction to the sun, w anisotropy
    vec4 u_SunRadiance;   // rgb radiance times intensity times the pass intensity
    vec4 u_Medium;        // x density, y height falloff, z base height, w start distance
    vec4 u_March;         // x steps, y maximum distance, z local light budget, w maximum opacity
};
struct LocalLight3D { vec4 positionRange; vec4 radianceIntensity; vec4 directionOuter; vec4 innerShadow; };
layout(binding=25) uniform LocalLighting3DUniform {
    vec4 u_LightCounts; vec4 u_AdditionalDirections[3]; vec4 u_AdditionalRadiance[3]; LocalLight3D u_LocalLights[32];
};
layout(binding=28) uniform LocalShadow3DUniform { mat4 u_LocalShadowMatrices[24]; vec4 u_LocalAtlas; };
layout(binding=26) uniform texture2D u_LocalShadowTexture;
layout(binding=5) uniform LocalFogVolumes3DUniform { vec4 u_VolumeAmbientCount; vec4 u_Volumes[24]; };

const float PI = 3.14159265359;

float henyeyGreenstein(float cosine, float g) {
    float denominator = 1.0 + g * g - 2.0 * g * cosine;
    return (1.0 - g * g) / (4.0 * PI * pow(max(denominator, 0.0001), 1.5));
}

// Whether the sun reaches a world-space point, from the cascade covering its view depth.
float sunVisibility(vec3 world, float viewDepth) {
    if (u_ShadowAtlas.w < 0.5 || viewDepth > u_CascadeSplits.z) { return 1.0; }
    int count = int(u_CascadeSplits.w);
    int cascade = min(viewDepth <= u_CascadeSplits.x ? 0 : (viewDepth <= u_CascadeSplits.y ? 1 : 2), count - 1);
    vec4 position;
    if (cascade == 0) { position = u_ShadowViewProjection0 * vec4(world, 1.0); }
    else if (cascade == 1) { position = u_ShadowViewProjection1 * vec4(world, 1.0); }
    else { position = u_ShadowViewProjection2 * vec4(world, 1.0); }
    vec3 projected = position.xyz / position.w;
    vec2 localUV = projected.xy * vec2(0.5, -0.5) + 0.5;
    if (projected.z < 0.0 || projected.z > 1.0 || any(lessThan(localUV, vec2(0.0))) || any(greaterThan(localUV, vec2(1.0)))) { return 1.0; }
    float cascadeCount = max(u_CascadeSplits.w, 1.0);
    vec2 uv = vec2((localUV.x + float(cascade)) / cascadeCount, localUV.y);
    vec2 minimum = vec2(float(cascade) / cascadeCount, 0.0) + u_ShadowAtlas.xy * 0.5;
    vec2 maximum = vec2(float(cascade + 1) / cascadeCount, 1.0) - u_ShadowAtlas.xy * 0.5;
    float stored = textureLod(sampler2D(u_DirectionalShadowTexture, u_Nearest), clamp(uv, minimum, maximum), 0.0).r;
    return projected.z - u_ShadowAtlas.z <= stored ? 1.0 : 0.0;
}

// Positive means lit. Unlike a binary comparison, the signed separation lets a
// step locate an occluder crossing inside the segment. Directional matrices are
// orthographic; dividing by their depth-row length puts cascade gaps into the
// same world-depth units before interpolation across a cascade boundary.
float sunShadowGap(vec3 world, float viewDepth) {
    if (u_ShadowAtlas.w < 0.5 || viewDepth > u_CascadeSplits.z) { return 10000.0; }
    int count = int(u_CascadeSplits.w);
    int cascade = min(viewDepth <= u_CascadeSplits.x ? 0 : (viewDepth <= u_CascadeSplits.y ? 1 : 2), count - 1);
    mat4 transform;
    if (cascade == 0) { transform = u_ShadowViewProjection0; }
    else if (cascade == 1) { transform = u_ShadowViewProjection1; }
    else { transform = u_ShadowViewProjection2; }
    vec4 position = transform * vec4(world, 1.0);
    vec3 projected = position.xyz / position.w;
    vec2 localUV = projected.xy * vec2(0.5, -0.5) + 0.5;
    if (projected.z < 0.0 || projected.z > 1.0 || any(lessThan(localUV, vec2(0.0))) || any(greaterThan(localUV, vec2(1.0)))) { return 10000.0; }
    float cascadeCount = max(u_CascadeSplits.w, 1.0);
    vec2 uv = vec2((localUV.x + float(cascade)) / cascadeCount, localUV.y);
    vec2 minimum = vec2(float(cascade) / cascadeCount, 0.0) + u_ShadowAtlas.xy * 0.5;
    vec2 maximum = vec2(float(cascade + 1) / cascadeCount, 1.0) - u_ShadowAtlas.xy * 0.5;
    float stored = textureLod(sampler2D(u_DirectionalShadowTexture, u_Nearest), clamp(uv, minimum, maximum), 0.0).r;
    vec3 depthRow = vec3(transform[0][2], transform[1][2], transform[2][2]);
    return (stored + u_ShadowAtlas.z - projected.z) / max(length(depthRow), 0.00000001);
}

// Beer-Lambert scattering over the lit part of a constant-density segment.
// Linear endpoint gaps give the exact crossing of a planar shadow boundary;
// an occluded prefix attenuates the lit suffix instead of adding light through it.
float litSegmentWeight(vec3 origin, vec3 direction, float viewRayZ, float startTravel, float stepLength,
    float startGap, float endGap, float opticalDepth, float wholeSegment) {
    if (startGap >= 0.0 && endGap >= 0.0) { return wholeSegment; }
    if (startGap < 0.0 && endGap < 0.0) { return 0.0; }
    // Stored shadow depth can jump at an atlas silhouette. Its gap magnitude is
    // then not a reliable distance to the crossing. Refine only those segments
    // whose endpoint visibility differs; fully lit/shadowed steps pay no extra
    // shadow fetches. The final interpolation remains exact for a planar gap.
    float lower = 0.0;
    float upper = 1.0;
    float lowerGap = startGap;
    float upperGap = endGap;
    for (int refine = 0; refine < 5; ++refine) {
        float middle = (lower + upper) * 0.5;
        float travel = startTravel + middle * stepLength;
        float gap = sunShadowGap(origin + direction * travel, travel * viewRayZ);
        if ((gap >= 0.0) == (lowerGap >= 0.0)) {
            lower = middle;
            lowerGap = gap;
        } else {
            upper = middle;
            upperGap = gap;
        }
    }
    float crossing = mix(lower, upper, clamp(lowerGap / (lowerGap - upperGap), 0.0, 1.0));
    if (startGap >= 0.0) { return 1.0 - exp(-opticalDepth * crossing); }
    return exp(-opticalDepth * crossing) * (1.0 - exp(-opticalDepth * (1.0 - crossing)));
}

float localVisibility(LocalLight3D light, vec3 world) {
    int slot=int(light.innerShadow.w);
    if(slot<0||slot>=4) { return 1.0; }
    vec3 ray=world-light.positionRange.xyz, a=abs(ray);
    int face=0;
    if(light.directionOuter.w<0.0) {
        face=a.x>=a.y&&a.x>=a.z?(ray.x>=0.0?0:1):(a.y>=a.z?(ray.y>=0.0?2:3):(ray.z>=0.0?4:5));
    }
    vec4 clip=u_LocalShadowMatrices[slot*6+face]*vec4(world,1.0);
    if(clip.w<=0.0) { return 1.0; }
    vec3 ndc=clip.xyz/clip.w;
    if(ndc.z<0.0||ndc.z>1.0||any(greaterThan(abs(ndc.xy),vec2(1.0)))) { return 1.0; }
    vec2 origin=vec2(float(face),float(slot))*u_LocalAtlas.z;
    vec2 uv=(origin+(ndc.xy*vec2(0.5,-0.5)+0.5)*u_LocalAtlas.z)*u_LocalAtlas.xy;
    uv=clamp(uv,(origin+0.5)*u_LocalAtlas.xy,(origin+u_LocalAtlas.z-0.5)*u_LocalAtlas.xy);
    float stored=textureLod(sampler2D(u_LocalShadowTexture,u_Nearest),uv,0.0).r;
    return ndc.z-light.innerShadow.y<=stored?1.0:0.0;
}

vec3 localRadiance(vec3 world, vec3 worldDirection) {
    vec3 result=vec3(0.0);
    int count=min(int(u_LightCounts.y),int(u_March.z));
    for(int i=0;i<8;++i) {
        if(i>=count) { break; }
        LocalLight3D light=u_LocalLights[i];
        vec3 delta=light.positionRange.xyz-world;
        float distance=length(delta),range=light.positionRange.w;
        if(distance>=range||range<=0.0) { continue; }
        vec3 direction=delta/max(distance,0.0001);
        float cutoff=max(0.0,1.0-pow(distance/range,4.0));
        float attenuation=cutoff*cutoff/max(distance*distance,0.04);
        if(light.directionOuter.w>=0.0) {
            attenuation*=smoothstep(light.directionOuter.w,light.innerShadow.x,dot(normalize(light.directionOuter.xyz),-direction));
        }
        if(attenuation<=0.0) { continue; }
        result+=light.radianceIntensity.rgb*max(light.radianceIntensity.w,0.0)*attenuation
            *henyeyGreenstein(dot(worldDirection,direction),u_SunDirection.w)*localVisibility(light,world);
    }
    return result*u_SunRadiance.w;
}

[[main]]
void volumetric_fog_fragment() {
    vec4 positionMetallic = textureLod(sampler2D(u_ViewPositionMetallic, u_Nearest), v_UV, 0.0);
    vec2 ndc = vec2(v_UV.x * 2.0 - 1.0, 1.0 - v_UV.y * 2.0);
    vec4 viewFar = u_InverseProjection * vec4(ndc, 1.0, 1.0);
    vec3 viewRay = normalize(viewFar.xyz / viewFar.w);
    bool hasSurface = length(positionMetallic.xyz) > 0.0001;
    float surfaceDistance = hasSurface ? length(positionMetallic.xyz) : u_March.y;
    float rangeEnd = min(surfaceDistance, u_March.y);
    float rangeStart = min(u_Medium.w, rangeEnd);
    int steps = int(u_March.x);
    float stepLength = (rangeEnd - rangeStart) / float(steps);
    if (stepLength <= 0.0) {
        o_Color = vec4(0.0);
        return;
    }
    vec3 worldDirection = normalize((u_InverseView * vec4(viewRay, 0.0)).xyz);
    vec3 origin = u_InverseView[3].xyz;
    float phase = henyeyGreenstein(dot(worldDirection, u_SunDirection.xyz), u_SunDirection.w);
    bool boundedMedium = u_VolumeAmbientCount.w > 0.0;
    float previousSunGap = 0.0;
    if (boundedMedium) {
        previousSunGap = sunShadowGap(origin + worldDirection * rangeStart, rangeStart * viewRay.z);
    }

    float transmittance = 1.0;
    vec3 scattered = vec3(0.0);
    float scatteredSun = 0.0;
    float localOpticalDepth=0.0;
    for (int index = 0; index < 64; ++index) {
        if (index >= steps) { break; }
        float travel = rangeStart + (float(index) + 0.5) * stepLength;
        vec3 world = origin + worldDirection * travel;
        float density = u_Medium.x * exp(clamp(-u_Medium.y * (world.y - u_Medium.z), -60.0, 60.0));
        vec3 scatteringDensity=vec3(density);
        float localDensity=0.0;
        for(int v=0;v<8;++v) {
            if(v>=int(u_VolumeAmbientCount.w)) { break; }
            vec4 lo=u_Volumes[v*3],hi=u_Volumes[v*3+1];
            vec3 edge=min(world-lo.xyz,hi.xyz-world);
            float fade=clamp(min(edge.x,min(edge.y,edge.z))/hi.w,0.0,1.0);
            float d=lo.w*fade;
            localDensity+=d; scatteringDensity+=d*u_Volumes[v*3+2].rgb;
        }
        float total=density+localDensity;
        float opticalDepth=total*stepLength;
        float segment=1.0-exp(-opticalDepth);
        float sunVisible=0.0;
        if (boundedMedium) {
            // One new endpoint lookup per step; reuse it as the next start.
            float endTravel = rangeStart + float(index + 1) * stepLength;
            float nextSunGap = sunShadowGap(origin + worldDirection * endTravel, endTravel * viewRay.z);
            float litWeight = litSegmentWeight(origin, worldDirection, viewRay.z,
                rangeStart + float(index) * stepLength, stepLength, previousSunGap, nextSunGap, opticalDepth, segment);
            previousSunGap = nextSunGap;
            vec3 source = segment * (localRadiance(world,worldDirection)*scatteringDensity
                +localDensity*u_VolumeAmbientCount.rgb)
                +litWeight*u_SunRadiance.rgb*phase*scatteringDensity;
            scattered += transmittance * source / max(total,0.000001);
        } else {
            // Preserve the established global height-fog integrator and references.
            sunVisible=sunVisibility(world,travel*viewRay.z);
            vec3 sun=u_SunRadiance.rgb*(phase*sunVisible);
            scattered+=transmittance*segment*(localRadiance(world,worldDirection)*scatteringDensity
                +sun*(scatteringDensity-vec3(density))+localDensity*u_VolumeAmbientCount.rgb)/max(total,0.000001);
        }
        transmittance*=exp(-total*stepLength);
        // Preserve the established global sun-only integrator and its reference frames.
        if (!boundedMedium) { scatteredSun+=density*stepLength*transmittance*sunVisible; }
        localOpticalDepth+=localDensity*stepLength;
    }
    o_Color = vec4(scattered+u_SunRadiance.rgb*(scatteredSun*phase),min(1.0-exp(-localOpticalDepth),u_March.w));
}
