// Shared by native Metal and WebGPU SPIR-V paths. All RGB values are diffuse irradiance / pi.
#ifdef ADA_LIGHTMAP
layout(binding=46) uniform texture2D u_DiffuseLightmap;
layout(binding=47) uniform sampler u_LightmapSampler;
#endif
#ifdef ADA_IRRADIANCE_GRID
layout(binding=43) uniform texture2D u_ProbeSH;
layout(binding=44) uniform texture2D u_ProbeVisibility;
layout(binding=48) uniform texture2D u_DynamicProbeSH;
layout(binding=45) uniform IrradianceGrid3DUniform {
    vec4 u_GridOriginIntensity;
    vec4 u_GridSpacingNormalBias;
    vec4 u_GridCountsVisibilityBias;
    vec4 u_GridQuality;
};
vec2 adaOctEncode(vec3 d) {
    d/=max(abs(d.x)+abs(d.y)+abs(d.z),0.000001);
    if(d.z<0.0) { d.xy=(1.0-abs(d.yx))*mix(vec2(-1.0),vec2(1.0),greaterThanEqual(d.xy,vec2(0.0))); }
    return d.xy*0.5+0.5;
}
vec3 adaProbeSH(ivec2 address,vec3 n,bool dynamicOnly) {
    float basis[9]=float[](0.2820947918,0.4886025119*n.y,0.4886025119*n.z,0.4886025119*n.x,
        1.0925484306*n.x*n.y,1.0925484306*n.y*n.z,0.3153915653*(3.0*n.z*n.z-1.0),
        1.0925484306*n.x*n.z,0.5462742153*(n.x*n.x-n.y*n.y));
    vec3 value=vec3(0.0);
    for(int i=0;i<9;++i) {
        if(!dynamicOnly) { value+=texelFetch(sampler2D(u_ProbeSH,u_IBLSampler),address+ivec2(i,0),0).rgb*basis[i]; }
        if(u_GridQuality.w>0.5) { value+=texelFetch(sampler2D(u_DynamicProbeSH,u_IBLSampler),address+ivec2(i,0),0).rgb*basis[i]; }
    }
    return max(value,vec3(0.0));
}
vec4 adaIrradianceGrid(vec3 world,vec3 normal,bool dynamicOnly) {
    if(u_GridQuality.y<0.5) { return vec4(0.0); }
    vec3 local=(world-u_GridOriginIntensity.xyz)/u_GridSpacingNormalBias.xyz;
    vec3 counts=u_GridCountsVisibilityBias.xyz;
    if(any(lessThan(local,vec3(0.0)))||any(greaterThan(local,counts-1.0))) { return vec4(0.0); }
    ivec3 cell=clamp(ivec3(floor(local)),ivec3(0),ivec3(counts)-2);
    vec3 blend=clamp(local-vec3(cell),vec3(0.0),vec3(1.0));
    vec3 edge=min(local,counts-1.0-local);
    float coverage=clamp(min(edge.x,min(edge.y,edge.z))*2.0,0.0,1.0);
    vec3 biased=world+normal*u_GridSpacingNormalBias.w;
    vec3 sum=vec3(0.0); float weights=0.0;
    int resolution=int(u_GridQuality.x);
    for(int z=0;z<2;++z) for(int y=0;y<2;++y) for(int x=0;x<2;++x) {
        ivec3 probe=cell+ivec3(x,y,z);
        ivec2 shAddress=ivec2(probe.x*9,probe.z*int(counts.y)+probe.y);
        float valid=texelFetch(sampler2D(u_ProbeSH,u_IBLSampler),shAddress,0).a;
        if(valid<0.5) { continue; }
        vec3 position=u_GridOriginIntensity.xyz+vec3(probe)*u_GridSpacingNormalBias.xyz;
        vec3 delta=biased-position; float distance=length(delta);
        ivec2 uv=clamp(ivec2(adaOctEncode(delta)*float(resolution)),ivec2(0),ivec2(resolution-1));
        ivec2 address=ivec2(probe.x,probe.z*int(counts.y)+probe.y)*resolution+uv;
        vec3 moments=texelFetch(sampler2D(u_ProbeVisibility,u_IBLSampler),address,0).rgb;
        float difference=max(distance-moments.x-u_GridCountsVisibilityBias.w,0.0);
        float variance=max(moments.y-moments.x*moments.x,0.0);
        float visibility=difference<=0.0?1.0:variance/max(variance+difference*difference,0.000001);
        visibility=pow(clamp(visibility,0.0,1.0),u_GridQuality.z);
        // Reject near-zero weights instead of introducing a light-leaking minimum weight.
        visibility=max(visibility-0.05,0.0)/0.95;
        vec3 factors=mix(1.0-blend,blend,vec3(float(x),float(y),float(z)));
        float weight=factors.x*factors.y*factors.z*visibility;
        sum+=adaProbeSH(shAddress,normal,dynamicOnly)*weight; weights+=weight;
    }
    // An interior point with no visible valid probe stays dark, rather than falling back to leaking global IBL.
    return vec4(weights>0.000001?sum/weights*u_GridOriginIntensity.w:vec3(0.0),coverage);
}
#endif
vec4 adaBakedDiffuse(vec3 world,vec3 normal,vec2 uv1) {
    vec4 lightmap=vec4(0.0);
#ifdef ADA_LIGHTMAP
    ivec2 size=textureSize(sampler2D(u_DiffuseLightmap,u_LightmapSampler),0);
    vec2 uv=clamp(uv1*u_LightmapScaleOffset.xy+u_LightmapScaleOffset.zw,0.5/vec2(size),1.0-0.5/vec2(size));
    lightmap=texture(sampler2D(u_DiffuseLightmap,u_LightmapSampler),uv);
    lightmap.rgb*=u_BakedParameters.x;
    lightmap.a=clamp(lightmap.a,0.0,1.0);
    if(lightmap.a>=0.999) {
#ifdef ADA_IRRADIANCE_GRID
        if(u_GridQuality.w>0.5) {
            vec4 dynamic=adaIrradianceGrid(world,normal,true);
            lightmap.rgb+=dynamic.rgb*dynamic.a;
        }
#endif
        return lightmap;
    }
#endif
#ifdef ADA_IRRADIANCE_GRID
    vec4 grid=adaIrradianceGrid(world,normal,false);
    float coverage=lightmap.a+(1.0-lightmap.a)*grid.a;
    vec3 value=lightmap.rgb*lightmap.a+grid.rgb*(1.0-lightmap.a)*grid.a;
    return vec4(value/max(coverage,0.000001),coverage);
#else
    return lightmap;
#endif
}
