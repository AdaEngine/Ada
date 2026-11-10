#version 450 core
#pragma stage : vert
layout(location=0) out vec2 v_UV;
[[main]]
void path_vertex() {
    vec2 uv=vec2(float(gl_VertexIndex >> 1u),float(gl_VertexIndex & 1u))*2.0;
    gl_Position=vec4(uv*vec2(2.0,-2.0)+vec2(-1.0,1.0),0,1); v_UV=uv;
}
#version 450 core
#pragma stage : frag
layout(location=0) in vec2 v_UV;
layout(location=0) out vec4 o_Color;
layout(binding=0) uniform texture2D u_Nodes;
layout(binding=1) uniform texture2D u_Triangles;
layout(binding=2) uniform texture2D u_Materials;
layout(binding=3) uniform texture2D u_Atlas;
layout(binding=5) uniform texture2D u_Lights;
layout(binding=6) uniform texture2D u_History;
layout(binding=7) uniform texture2D u_Environment;
layout(binding=8) uniform sampler u_Nearest;
layout(binding=9) uniform sampler u_Linear;
layout(binding=10) uniform texture2D u_Normal;
layout(binding=11) uniform texture2D u_Position;
layout(binding=12) uniform texture2D u_Albedo;   // G-buffer base colour (path-tracing surface outputs)
layout(binding=13) uniform texture2D u_Emission; // G-buffer emission
layout(binding=14) uniform texture2D u_InputB;   // pass-specific second input
layout(binding=15) uniform texture2D u_InputC;   // pass-specific third input
layout(binding=4) uniform PathUniform {
    mat4 u_InverseProjection;
    mat4 u_InverseView;
    vec4 u_Counts; // nodes, lights, spp, surface interactions
    vec4 u_Trace; // distance, bias, radiance clamp, history frames
    vec4 u_Frame; // frame seed, pass (0 trace/1 filter/2 reconstruct), atlas rows, linear environment texture
    vec4 u_Zenith;
    vec4 u_Horizon;
    vec4 u_Ground;
    vec4 u_Sky; // environment texture enabled, intensity, rotation, procedural enabled
    vec4 u_Hybrid; // x: first hit from the raster G-buffer
    mat4 u_PreviousViewProjection; // unjittered, previous frame of this view
    mat4 u_PreviousView;
    vec4 u_Denoise; // x: wavelet step, y: minimum history weight, z: trace writes demodulated light, w: final remodulates
};
const float PI=3.141592653589793;
uint randomState;
float randomValue() {
    randomState=randomState*747796405u+2891336453u;
    uint word=((randomState >> ((randomState >> 28u)+4u)) ^ randomState)*277803737u;
    return float((word >> 22u) ^ word)/4294967296.0;
}
vec4 tri(int index) { return texelFetch(sampler2D(u_Triangles,u_Nearest),ivec2(index%2048,index/2048),0); }
vec4 node(int index) { return texelFetch(sampler2D(u_Nodes,u_Nearest),ivec2(index%2048,index/2048),0); }
vec4 material(int index) { return texelFetch(sampler2D(u_Materials,u_Nearest),ivec2(index%2048,index/2048),0); }
vec4 light(int index) { return texelFetch(sampler2D(u_Lights,u_Nearest),ivec2(index%2048,index/2048),0); }
vec4 atlas(float tile,vec2 uv) {
    if(tile<0.0) return vec4(1.0);
    // Half texel inset prevents adjacent materials bleeding into a repeated tile.
    vec2 size=vec2(textureSize(sampler2D(u_Atlas,u_Linear),0));
    float tileSize=size.x/16.0;
    vec2 pixel=clamp(fract(uv)*tileSize,vec2(0.5),vec2(tileSize-0.5));
    vec2 origin=vec2(mod(tile,16.0),floor(tile/16.0))*tileSize;
    return textureLod(sampler2D(u_Atlas,u_Linear),(origin+pixel)/size,0.0);
}
vec3 srgb(vec3 color) {
    return mix(color/12.92,pow((color+0.055)/1.055,vec3(2.4)),greaterThan(color,vec3(0.04045)));
}
vec3 sky(vec3 direction) {
    float angle=u_Sky.z;
    direction.xz=mat2(cos(angle),-sin(angle),sin(angle),cos(angle))*direction.xz;
    if(u_Sky.x>0.5) {
        vec2 uv=vec2(atan(direction.z,direction.x)/(2.0*PI)+0.5,asin(clamp(direction.y,-1.0,1.0))/PI+0.5);
        vec3 value=max(textureLod(sampler2D(u_Environment,u_Linear),uv,0.0).rgb,vec3(0));
        return (u_Frame.w>0.5?value:srgb(value))*u_Sky.y;
    }
    if(u_Sky.w<0.5) return vec3(0);
    return srgb(mix(u_Horizon.rgb,direction.y>=0.0?u_Zenith.rgb:u_Ground.rgb,pow(abs(direction.y),0.6)))*u_Sky.y;
}
mat3 basis(vec3 normal) {
    vec3 t=normalize(abs(normal.z)<0.9?cross(vec3(0,0,1),normal):cross(vec3(0,1,0),normal));
    return mat3(t,cross(normal,t),normal);
}
bool boxHit(vec3 origin,vec3 direction,vec3 lo,vec3 hi,float distance) {
    // Parallel slabs need an explicit containment test; 0 * infinity is undefined.
    float nearT=0.0,farT=distance;
    for(int axis=0;axis<3;++axis) {
        if(abs(direction[axis])<1e-9) { if(origin[axis]<lo[axis] || origin[axis]>hi[axis]) return false; }
        else {
            float a=(lo[axis]-origin[axis])/direction[axis],b=(hi[axis]-origin[axis])/direction[axis];
            nearT=max(nearT,min(a,b)); farT=min(farT,max(a,b));
            if(farT<nearT) return false;
        }
    }
    return true;
}
// Returns the closest actual world triangle, with optional cast-shadow filtering.
int intersectScene(vec3 origin,vec3 direction,inout float distance,out vec3 bary,bool shadowRay) {
    int hit=-1; bary=vec3(0); int cursor=0;
    while(cursor<int(u_Counts.x)) {
        vec4 lo=node(cursor*3),hi=node(cursor*3+1),info=node(cursor*3+2);
        if(!boxHit(origin,direction,lo.xyz,hi.xyz,distance)) { cursor=int(lo.w); continue; }
        int count=int(info.x);
        for(int i=0;i<4;++i) {
            if(i>=count) break;
            int index=(int(hi.w)+i)*12;
            vec4 a=tri(index),b=tri(index+1),c=tri(index+2);
            if(shadowRay && (int(b.w)&1)==0) continue;
            vec3 e1=b.xyz-a.xyz,e2=c.xyz-a.xyz,p=cross(direction,e2);
            float determinant=dot(e1,p);
            if(abs(determinant)<1e-10) continue;
            int m=int(a.w)*5;
            if(material(m+2).w<0.5 && determinant<0.0) continue;
            vec3 t=origin-a.xyz;
            float u=dot(t,p)/determinant;
            vec3 q=cross(t,e1);
            float v=dot(direction,q)/determinant,travel=dot(e2,q)/determinant;
            if(u<0.0 || v<0.0 || u+v>1.0 || travel<=u_Trace.y || travel>=distance) continue;
            vec3 weights=vec3(1.0-u-v,u,v);
            vec2 uv=tri(index+6).xy*weights.x+tri(index+7).xy*weights.y+tri(index+8).xy*weights.z;
            float alpha=material(m).w*atlas(material(m+3).x,uv).a;
            int mode=int(material(m+4).x);
            if(mode==1 && alpha<material(m+2).z) continue;
            if(mode==2 && randomValue()>alpha) continue;
            hit=index; bary=weights; distance=travel;
            if(shadowRay) return hit;
        }
        cursor+=1;
    }
    return hit;
}
struct Surface { vec3 position; vec3 normal; vec3 geometric; vec3 color; vec3 emission; float roughness; float metal; bool receives; };
Surface surfaceAt(int hit,vec3 bary,vec3 origin,vec3 direction,float distance) {
    Surface s;
    int m=int(tri(hit).w)*5;
    vec4 factor=material(m),parameters=material(m+2),tiles=material(m+3);
    vec4 uv=tri(hit+6)*bary.x+tri(hit+7)*bary.y+tri(hit+8)*bary.z;
    vec4 other=tri(hit+9)*bary.x+tri(hit+10)*bary.y+tri(hit+11)*bary.z;
    s.position=origin+direction*distance;
    s.geometric=normalize(cross(tri(hit+1).xyz-tri(hit).xyz,tri(hit+2).xyz-tri(hit).xyz));
    vec3 n=tri(hit+3).xyz*bary.x+tri(hit+4).xyz*bary.y+tri(hit+5).xyz*bary.z;
    s.normal=dot(n,n)>0.00001?normalize(n):s.geometric;
    if(dot(s.geometric,direction)>0.0) s.geometric=-s.geometric;
    if(dot(s.normal,direction)>0.0) s.normal=-s.normal;
    if(tiles.w>=0.0) {
        vec2 du=tri(hit+10).zw-tri(hit+9).zw,dv=tri(hit+11).zw-tri(hit+9).zw;
        float det=du.x*dv.y-du.y*dv.x;
        if(abs(det)>0.000001) {
            vec3 e1=tri(hit+1).xyz-tri(hit).xyz,e2=tri(hit+2).xyz-tri(hit).xyz;
            vec3 t=(e1*dv.y-e2*du.y)/det;
            t=normalize(t-s.normal*dot(s.normal,t));
            vec3 b=cross(s.normal,t)*sign(det);
            vec3 mapped=atlas(tiles.w,other.zw).xyz*2.0-1.0;
            mapped.xy*=material(m+4).y;
            vec3 mappedNormal=normalize(mat3(t,b,s.normal)*mapped);
            if(dot(mappedNormal,s.geometric)>0.0) s.normal=mappedNormal;
        }
    }
    s.color=clamp(factor.rgb*(tiles.x>=0.0?srgb(atlas(tiles.x,uv.xy).rgb):vec3(1)),vec3(0),vec3(1));
    vec4 mr=atlas(tiles.y,uv.zw);
    s.metal=clamp(parameters.x*mr.b,0.0,1.0); s.roughness=clamp(parameters.y*mr.g,0.04,1.0);
    s.emission=max(material(m+1).rgb,vec3(0))*(tiles.z>=0.0?srgb(atlas(tiles.z,other.xy).rgb):vec3(1));
    s.receives=(int(tri(hit+1).w)&2)!=0;
    return s;
}
vec3 fresnel(vec3 f0,float cosine) { return f0+(1.0-f0)*pow(1.0-clamp(cosine,0.0,1.0),5.0); }
vec3 brdf(Surface s,vec3 view,vec3 direction) {
    float nv=max(dot(s.normal,view),0.0001),nl=max(dot(s.normal,direction),0.0);
    if(nl<=0.0) return vec3(0);
    vec3 halfVector=normalize(view+direction);
    float nh=max(dot(s.normal,halfVector),0.0),vh=max(dot(view,halfVector),0.0);
    float a=s.roughness*s.roughness,a2=a*a;
    float denominator=nh*nh*(a2-1.0)+1.0;
    float d=a2/max(PI*denominator*denominator,1e-10);
    float gv=2.0*nv/(nv+sqrt(a2+(1.0-a2)*nv*nv));
    float gl=2.0*nl/(nl+sqrt(a2+(1.0-a2)*nl*nl));
    vec3 f=fresnel(mix(vec3(0.04),s.color,s.metal),vh);
    return ((1.0-f)*(1.0-s.metal)*s.color/PI+f*d*gv*gl/max(4.0*nv*nl,0.0001))*nl;
}
vec3 sampleLight(Surface s,vec3 view,int selected) {
    selected*=4;
    vec4 a=light(selected),b=light(selected+1),c=light(selected+2),d=light(selected+3);
    vec3 direction; float distance=u_Trace.x,attenuation=1.0;
    if(a.w<0.5) {
        direction=normalize(a.xyz);
        if(d.z>0.0) {
            float r=sqrt(randomValue())*d.z,phi=2.0*PI*randomValue();
            direction=normalize(direction+basis(direction)*vec3(r*cos(phi),r*sin(phi),0));
        }
    } else {
        vec3 delta=a.xyz-s.position; distance=length(delta);
        if(distance>=b.w || distance<0.00001) return vec3(0);
        direction=delta/distance;
        float cutoff=max(0.0,1.0-pow(distance/b.w,4.0));
        attenuation=cutoff*cutoff/max(distance*distance,0.01);
        if(a.w>1.5) attenuation*=smoothstep(d.y,d.x,dot(-direction,normalize(c.xyz)));
    }
    if(dot(s.normal,direction)<=0.0 || dot(s.geometric,direction)<=0.0) return vec3(0);
    if(s.receives && c.w>0.5) {
        float maximum=max(u_Trace.y,distance-u_Trace.y*2.0); vec3 bary;
        if(intersectScene(s.position+s.geometric*u_Trace.y*2.0,direction,maximum,bary,true)>=0) return vec3(0);
    }
    return brdf(s,view,direction)*max(b.rgb,vec3(0))*attenuation;
}
vec3 directLight(Surface s,vec3 view) {
    // Deterministic enumeration removes light-selection noise from the small authored game light set.
    vec3 result=vec3(0);
    for(int index=0;index<int(u_Counts.y);++index) result+=sampleLight(s,view,index);
    return result;
}
// Samples the next direction from a diffuse/GGX mixture and updates the throughput; false ends the path.
bool scatter(Surface s,vec3 view,inout vec3 throughput,out vec3 nextDirection) {
    vec3 f0=mix(vec3(0.04),s.color,s.metal);
    float chance=clamp(max(f0.r,max(f0.g,f0.b)),0.1,0.9);
    if(randomValue()<chance) {
        float u=randomValue(),phi=2.0*PI*randomValue(),a=s.roughness*s.roughness;
        float cosine=sqrt((1.0-u)/max(1.0+(a*a-1.0)*u,0.000001));
        vec3 halfVector=normalize(basis(s.normal)*vec3(sqrt(max(0.0,1.0-cosine*cosine))*vec2(cos(phi),sin(phi)),cosine));
        nextDirection=reflect(-view,halfVector);
    } else {
        float r=sqrt(randomValue()),phi=2.0*PI*randomValue();
        nextDirection=normalize(basis(s.normal)*vec3(r*cos(phi),r*sin(phi),sqrt(max(0.0,1.0-r*r))));
    }
    float nl=dot(s.normal,nextDirection);
    if(nl<=0.0 || dot(s.geometric,nextDirection)<=0.0) return false;
    vec3 h=normalize(view+nextDirection);
    float nh=max(dot(s.normal,h),0.0),a=s.roughness*s.roughness,a2=a*a;
    float denominator=nh*nh*(a2-1.0)+1.0;
    float d=a2/max(PI*denominator*denominator,1e-10);
    float pdf=(1.0-chance)*nl/PI+chance*d*nh/max(4.0*abs(dot(view,h)),0.00001);
    throughput*=brdf(s,view,nextDirection)/max(pdf,1e-8);
    return true;
}
// Traces from `origin`; `firstBounce` counts interactions already shaded by the caller.
vec3 path(vec3 origin,vec3 direction,int firstBounce) {
    vec3 throughput=vec3(1),radiance=vec3(0);
    for(int bounce=firstBounce;bounce<8;++bounce) {
        if(bounce>=int(u_Counts.w)) break;
        float distance=u_Trace.x; vec3 bary;
        int hit=intersectScene(origin,direction,distance,bary,false);
        if(hit<0) { radiance+=throughput*sky(direction); break; }
        Surface s=surfaceAt(hit,bary,origin,direction,distance);
        radiance+=throughput*(s.emission+directLight(s,-direction));
        vec3 nextDirection;
        if(!scatter(s,-direction,throughput,nextDirection)) break;
        if(bounce>=2) {
            float survive=clamp(max(throughput.r,max(throughput.g,throughput.b)),0.05,0.95);
            if(randomValue()>survive) break;
            throughput/=survive;
        }
        origin=s.position+s.geometric*u_Trace.y*2.0; direction=nextDirection;
    }
    return radiance;
}
// The raster G-buffer's surface at `uv`: full model detail, independent of the traced LOD geometry.
bool gbufferSurface(vec2 uv,out Surface s,out vec3 view) {
    if(u_Hybrid.x<0.5) return false;
    vec4 normalRoughness=textureLod(sampler2D(u_Normal,u_Nearest),uv,0);
    if(dot(normalRoughness.xyz,normalRoughness.xyz)<0.01) return false;
    vec4 positionMetallic=textureLod(sampler2D(u_Position,u_Nearest),uv,0);
    s.position=(u_InverseView*vec4(positionMetallic.xyz,1)).xyz;
    s.normal=normalize(mat3(u_InverseView)*normalRoughness.xyz);
    view=normalize(u_InverseView[3].xyz-s.position);
    if(dot(s.normal,view)<0.0) s.normal=-s.normal;
    // The G-buffer has no geometric normal; the shading normal also offsets continuation rays.
    s.geometric=s.normal;
    s.color=textureLod(sampler2D(u_Albedo,u_Nearest),uv,0).rgb;
    s.emission=max(textureLod(sampler2D(u_Emission,u_Nearest),uv,0).rgb,vec3(0));
    s.roughness=clamp(normalRoughness.w,0.04,1.0); s.metal=clamp(positionMetallic.w,0.0,1.0); s.receives=true;
    return true;
}
bool hasSurface(vec2 uv) {
    vec3 n=textureLod(sampler2D(u_Normal,u_Nearest),uv,0).xyz;
    return dot(n,n)>0.01;
}
// Base colour that divides lighting before filtering, so texture detail is never blurred. 1 off surfaces.
vec3 demodulation(vec2 uv) {
    if(u_Hybrid.x<0.5 || !hasSurface(uv)) return vec3(1);
    return max(textureLod(sampler2D(u_Albedo,u_Nearest),uv,0).rgb,vec3(0.03));
}
vec3 emissionAt(vec2 uv) {
    if(u_Hybrid.x<0.5 || !hasSurface(uv)) return vec3(0);
    return max(textureLod(sampler2D(u_Emission,u_Nearest),uv,0).rgb,vec3(0));
}
float luminance(vec3 c) { return dot(c,vec3(0.2126,0.7152,0.0722)); }
// Pass 1: reproject the previous frame's accumulated light (input B) through this pixel's world position, reject it
// where the previous guide (input C: world normal and camera distance) disagrees, and blend the new sample (input A).
vec4 temporalPass() {
    vec3 current=textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb;
    vec4 normal=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0);
    if(dot(normal.xyz,normal.xyz)<0.01 || u_Trace.w<0.5) return vec4(current,1);
    vec3 viewPosition=textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).xyz;
    vec3 world=(u_InverseView*vec4(viewPosition,1)).xyz;
    vec3 worldNormal=normalize(mat3(u_InverseView)*normal.xyz);
    vec4 clip=u_PreviousViewProjection*vec4(world,1);
    vec4 history=vec4(0);
    if(clip.w>0.0001) {
        vec2 uv=clip.xy/clip.w*vec2(0.5,-0.5)+0.5;
        if(all(greaterThanEqual(uv,vec2(0))) && all(lessThanEqual(uv,vec2(1)))) {
            vec4 guide=textureLod(sampler2D(u_InputC,u_Nearest),uv,0);
            float expected=length((u_PreviousView*vec4(world,1)).xyz);
            if(dot(guide.xyz,worldNormal)>0.9 && abs(guide.w-expected)<0.05*expected+0.02)
                history=textureLod(sampler2D(u_InputB,u_Linear),uv,0);
        }
    }
    if(history.a>0.0) {
        // Clamp history to the current neighbourhood (mean +- 2 sigma per channel): a light that switches off or
        // turns away is followed at once, while ordinary sample noise keeps the range wide enough to converge.
        vec2 texel=1.0/vec2(textureSize(sampler2D(u_History,u_Nearest),0));
        vec3 mean=vec3(0),square=vec3(0);
        for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
            vec3 value=textureLod(sampler2D(u_History,u_Nearest),clamp(v_UV+vec2(x,y)*texel,vec2(0),vec2(1)),0).rgb;
            mean+=value; square+=value*value;
        }
        mean/=9.0;
        vec3 sigma=sqrt(max(square/9.0-mean*mean,vec3(0)));
        history.rgb=clamp(history.rgb,mean-2.0*sigma,mean+2.0*sigma);
    }
    float frames=min(history.a+1.0,1024.0);
    return vec4(mix(history.rgb,current,max(1.0/frames,u_Denoise.y)),frames);
}
// Pass 2: this frame's guide for the next frame's reprojection.
vec4 guidePass() {
    vec4 normal=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0);
    if(dot(normal.xyz,normal.xyz)<0.01) return vec4(0);
    vec3 viewPosition=textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).xyz;
    return vec4(normalize(mat3(u_InverseView)*normal.xyz),length(viewPosition));
}
// Pass 3: one edge-aware a-trous wavelet iteration with spacing u_Denoise.x, guided by normal, depth and the
// local luminance variance, so flat noisy regions smooth while edges and texture-independent detail stay.
vec4 waveletPass() {
    vec4 center=textureLod(sampler2D(u_History,u_Nearest),v_UV,0);
    vec4 normal=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0);
    if(dot(normal.xyz,normal.xyz)<0.01) return center;
    vec2 texel=1.0/vec2(textureSize(sampler2D(u_History,u_Nearest),0));
    float mean=0.0,square=0.0;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        float l=luminance(textureLod(sampler2D(u_History,u_Nearest),clamp(v_UV+vec2(x,y)*texel,vec2(0),vec2(1)),0).rgb);
        mean+=l; square+=l*l;
    }
    mean/=9.0;
    float sigma=4.0*sqrt(max(square/9.0-mean*mean,0.0))+0.0001;
    float depth=length(textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).xyz);
    float centerLuminance=luminance(center.rgb);
    const float kernel[3]=float[3](0.375,0.25,0.0625);
    vec3 sum=vec3(0); float weights=0.0;
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
        vec2 uv=v_UV+vec2(x,y)*texel*u_Denoise.x;
        if(any(lessThan(uv,vec2(0))) || any(greaterThan(uv,vec2(1)))) continue;
        vec4 otherNormal=textureLod(sampler2D(u_Normal,u_Nearest),uv,0);
        if(dot(otherNormal.xyz,otherNormal.xyz)<0.01) continue;
        vec3 value=textureLod(sampler2D(u_History,u_Nearest),uv,0).rgb;
        float otherDepth=length(textureLod(sampler2D(u_Position,u_Nearest),uv,0).xyz);
        float weight=kernel[abs(x)]*kernel[abs(y)];
        weight*=pow(max(dot(normalize(normal.xyz),normalize(otherNormal.xyz)),0.0),128.0);
        weight*=exp(-abs(depth-otherDepth)/(0.01*depth*u_Denoise.x+0.001));
        weight*=exp(-abs(centerLuminance-luminance(value))/sigma);
        sum+=value*weight; weights+=weight;
    }
    return vec4(weights>0.00001?sum/weights:center.rgb,center.a);
}
// Pass 4: geometry-aware reconstruction at output resolution, then remodulation with the full-resolution surface.
vec4 finalPass() {
    vec3 n=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0).xyz;
    vec3 p=textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).xyz;
    vec2 size=vec2(textureSize(sampler2D(u_History,u_Nearest),0));
    vec2 center=floor(v_UV*size-0.5),fraction=fract(v_UV*size-0.5);
    vec3 sum=vec3(0); float weightSum=0.0;
    for(int y=0;y<2;++y) for(int x=0;x<2;++x) {
        vec2 uv=clamp((center+vec2(x,y)+0.5)/size,vec2(0.0),vec2(1.0));
        vec3 otherN=textureLod(sampler2D(u_Normal,u_Nearest),uv,0).xyz;
        vec3 otherP=textureLod(sampler2D(u_Position,u_Nearest),uv,0).xyz;
        float weight=(x==0?1.0-fraction.x:fraction.x)*(y==0?1.0-fraction.y:fraction.y);
        bool surface=dot(n,n)>0.01,otherSurface=dot(otherN,otherN)>0.01;
        if(surface!=otherSurface) weight=0.0;
        if(surface && otherSurface) weight*=pow(max(dot(normalize(n),normalize(otherN)),0.0),16.0)*exp(-abs(p.z-otherP.z)/max(0.02,p.z*0.01));
        sum+=textureLod(sampler2D(u_History,u_Nearest),uv,0).rgb*weight; weightSum+=weight;
    }
    vec3 result=weightSum>0.00001?sum/weightSum:textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb;
    if(u_Denoise.w>0.5) result=result*demodulation(v_UV)+emissionAt(v_UV);
    return vec4(result,1);
}
// Pass 5: Ray Reconstruction guides; u_Denoise.x selects diffuse albedo (0), specular albedo (1) or world normal
// with roughness (2).
vec4 rayReconstructionGuidePass() {
    vec4 normal=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0);
    if(dot(normal.xyz,normal.xyz)<0.01) return vec4(0);
    if(u_Denoise.x>1.5) return vec4(normalize(mat3(u_InverseView)*normal.xyz),normal.w);
    vec3 base=textureLod(sampler2D(u_Albedo,u_Nearest),v_UV,0).rgb;
    float metal=textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).w;
    return vec4(u_Denoise.x<0.5 ? base*(1.0-metal) : mix(vec3(0.04),base,metal),1);
}
[[main]]
void path_fragment() {
    // Pass 0 traces; 1 temporal, 2 guide and 3 wavelet denoise; 4 reconstructs the output; 5 writes RR guides.
    if(u_Frame.y>4.5) { o_Color=rayReconstructionGuidePass(); return; }
    if(u_Frame.y>3.5) { o_Color=finalPass(); return; }
    if(u_Frame.y>2.5) { o_Color=waveletPass(); return; }
    if(u_Frame.y>1.5) { o_Color=guidePass(); return; }
    if(u_Frame.y>0.5) { o_Color=temporalPass(); return; }
    uvec2 pixel=uvec2(gl_FragCoord.xy);
    randomState=pixel.x*1973u+pixel.y*9277u+uint(u_Frame.x)*26699u+911u;
    vec3 color=vec3(0);
    Surface first; vec3 firstView;
    bool hybrid=gbufferSurface(v_UV,first,firstView);
    if(u_Hybrid.x>0.5 && !hybrid) {
        // The raster pass drew nothing here: the sky. Never trace it, so path-tracing-only proxies stay invisible.
        vec2 ndc=v_UV*vec2(2,-2)+vec2(-1,1);
        vec4 nearPoint=u_InverseProjection*vec4(ndc,0,1),farPoint=u_InverseProjection*vec4(ndc,1,1);
        vec3 direction=normalize(mat3(u_InverseView)*(farPoint.xyz/farPoint.w-nearPoint.xyz/nearPoint.w));
        o_Color=vec4(clamp(sky(direction),vec3(0),vec3(u_Trace.z)),1); return;
    }
    for(int sampleIndex=0;sampleIndex<8;++sampleIndex) {
        if(sampleIndex>=int(u_Counts.z)) break;
        if(hybrid) {
            vec3 throughput=vec3(1),nextDirection;
            vec3 lighting=directLight(first,firstView);
            if(int(u_Counts.w)>1 && scatter(first,firstView,throughput,nextDirection))
                lighting+=throughput*path(first.position+first.geometric*u_Trace.y*2.0,nextDirection,1);
            // Clamp only the light: emission is added after, so demodulation removes it exactly.
            color+=clamp(lighting,vec3(0),vec3(u_Trace.z))+first.emission;
            continue;
        }
        vec2 size=vec2(textureSize(sampler2D(u_History,u_Nearest),0));
        vec2 uv=v_UV+(vec2(randomValue(),randomValue())-0.5)/size;
        vec2 ndc=uv*vec2(2,-2)+vec2(-1,1);
        vec4 nearPoint=u_InverseProjection*vec4(ndc,0,1),farPoint=u_InverseProjection*vec4(ndc,1,1);
        vec3 viewOrigin=nearPoint.xyz/nearPoint.w;
        vec3 direction=normalize(mat3(u_InverseView)*(farPoint.xyz/farPoint.w-viewOrigin));
        vec3 origin=(u_InverseView*vec4(viewOrigin,1)).xyz;
        color+=clamp(path(origin,direction,0),vec3(0),vec3(u_Trace.z));
    }
    color/=u_Counts.z;
    if(u_Denoise.z>0.5) {
        // Denoisers filter light without the surface's own colour and emission; the final pass restores both.
        o_Color=vec4(max(color-emissionAt(v_UV),vec3(0))/demodulation(v_UV),1); return;
    }
    // Plain accumulation of a still view (reference mode).
    if(u_Trace.w>0.0) color=mix(color,textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb,u_Trace.w/(u_Trace.w+1.0));
    o_Color=vec4(color,1);
}
