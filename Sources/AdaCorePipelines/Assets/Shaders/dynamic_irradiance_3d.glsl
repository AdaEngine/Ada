#version 450 core
#pragma stage : vert
layout(location=0) out vec2 v_UV;
[[main]]
void dynamic_probe_vertex() {
    vec2 uv=vec2(float(gl_VertexIndex>>1u),float(gl_VertexIndex&1u))*2.0;
    gl_Position=vec4(uv*vec2(2.0,-2.0)+vec2(-1.0,1.0),0.0,1.0); v_UV=uv;
}
#version 450 core
#pragma stage : frag
layout(location=0) in vec2 v_UV;
layout(location=0) out vec4 o_Color;
layout(binding=0) uniform texture2D u_Positions;
layout(binding=1) uniform texture2D u_Normals;
layout(binding=2) uniform texture2D u_Albedo;
layout(binding=3) uniform texture2D u_Previous;
layout(binding=5) uniform sampler u_Nearest;
layout(binding=6) uniform texture2D u_StaticSH;
layout(binding=4) uniform DynamicIrradiance3DUniform { vec4 u_Grid; vec4 u_Update; vec4 u_Blend; };
struct LocalLight3D { vec4 positionRange; vec4 radianceIntensity; vec4 directionOuter; vec4 innerShadow; };
layout(binding=25) uniform LocalLighting3DUniform {
    vec4 u_LightCounts; vec4 u_AdditionalDirections[3]; vec4 u_AdditionalRadiance[3]; LocalLight3D u_LocalLights[32];
};
layout(binding=28) uniform LocalShadow3DUniform { mat4 u_LocalShadowMatrices[24]; vec4 u_LocalAtlas; };
layout(binding=26) uniform texture2D u_LocalShadowTexture;
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

vec3 incoming(vec3 world,vec3 normal) {
    vec3 result=vec3(0.0);
    for(int i=0;i<4;++i) {
        if(i>=int(u_Update.w)) { break; }
        LocalLight3D light=u_LocalLights[i];
        vec3 delta=light.positionRange.xyz-world;
        float distance=length(delta),range=light.positionRange.w;
        if(distance>=range||range<=0.0) { continue; }
        vec3 direction=delta/max(distance,0.0001);
        float cosine=max(dot(normal,direction),0.0);
        if(cosine<=0.0) { continue; }
        float ratio=distance/range,cutoff=max(1.0-ratio*ratio*ratio*ratio,0.0);
        float attenuation=cutoff*cutoff/max(distance*distance,0.01);
        if(light.directionOuter.w>=0.0) {
            attenuation*=smoothstep(light.directionOuter.w,light.innerShadow.x,dot(-direction,light.directionOuter.xyz));
        }
        if(attenuation>0.0) {
            result+=light.radianceIntensity.rgb*(light.radianceIntensity.w*attenuation*cosine*
                localVisibility(light,world+normal*0.012)/3.14159265359);
        }
    }
    return min(max(result,vec3(0.0)),vec3(32.0));
}
[[main]]
void dynamic_probe_fragment() {
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    int nx=int(u_Grid.x),count=int(u_Grid.x*u_Grid.y*u_Grid.z),samples=int(u_Grid.w);
    int probe=pixel.y*nx+pixel.x/9,coefficient=pixel.x%9;
    if(u_Update.w<0.5||texelFetch(sampler2D(u_StaticSH,u_Nearest),ivec2(pixel.x/9*9,pixel.y),0).a<0.5) {
        o_Color=vec4(0.0); return;
    }
    vec4 previous=u_Update.z>0.5?vec4(0.0):texelFetch(sampler2D(u_Previous,u_Nearest),pixel,0);
    int age=(probe-int(u_Update.x)+count)%count;
    if(age>=int(u_Update.y)) { o_Color=previous; return; }
    vec3 value=vec3(0.0);
    for(int i=0;i<256;++i) {
        if(i>=samples) { break; }
        ivec2 address=ivec2(pixel.x/9*samples+i,pixel.y);
        vec4 hit=texelFetch(sampler2D(u_Positions,u_Nearest),address,0);
        if(hit.a<0.5) { continue; }
        vec3 normal=normalize(texelFetch(sampler2D(u_Normals,u_Nearest),address,0).xyz);
        vec3 albedo=clamp(texelFetch(sampler2D(u_Albedo,u_Nearest),address,0).rgb,vec3(0.0),vec3(0.96));
        float y=1.0-2.0*(float(i)+0.5)/float(samples),r=sqrt(max(1.0-y*y,0.0)),phi=float(i)*2.399963229728653;
        vec3 d=vec3(r*cos(phi),y,r*sin(phi));
        float basis[9]=float[](0.2820947918,0.4886025119*d.y,0.4886025119*d.z,0.4886025119*d.x,
            1.0925484306*d.x*d.y,1.0925484306*d.y*d.z,0.3153915653*(3.0*d.z*d.z-1.0),
            1.0925484306*d.x*d.z,0.5462742153*(d.x*d.x-d.y*d.y));
        float convolution=coefficient==0?1.0:(coefficient<4?0.6666666667:0.25);
        value+=albedo*incoming(hit.xyz,normal)*(basis[coefficient]*convolution*12.56637061436/float(samples));
    }
    o_Color=vec4(mix(value*u_Blend.y,previous.rgb,u_Update.z>0.5?0.0:u_Blend.x),1.0);
}
