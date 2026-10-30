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
    vec2 pixel=clamp(fract(uv)*128.0,vec2(0.5),vec2(127.5));
    vec2 origin=vec2(mod(tile,16.0),floor(tile/16.0))*128.0;
    return textureLod(sampler2D(u_Atlas,u_Linear),(origin+pixel)/vec2(2048.0,u_Frame.z*128.0),0.0);
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
vec3 path(vec3 origin,vec3 direction) {
    vec3 throughput=vec3(1),radiance=vec3(0);
    for(int bounce=0;bounce<8;++bounce) {
        if(bounce>=int(u_Counts.w)) break;
        float distance=u_Trace.x; vec3 bary;
        int hit=intersectScene(origin,direction,distance,bary,false);
        if(hit<0) { radiance+=throughput*sky(direction); break; }
        Surface s=surfaceAt(hit,bary,origin,direction,distance);
        radiance+=throughput*(s.emission+directLight(s,-direction));
        vec3 view=-direction;
        vec3 f0=mix(vec3(0.04),s.color,s.metal);
        float chance=clamp(max(f0.r,max(f0.g,f0.b)),0.1,0.9);
        vec3 nextDirection;
        float pdf;
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
        if(nl<=0.0 || dot(s.geometric,nextDirection)<=0.0) break;
        vec3 h=normalize(view+nextDirection);
        float nh=max(dot(s.normal,h),0.0),a=s.roughness*s.roughness,a2=a*a;
        float denominator=nh*nh*(a2-1.0)+1.0;
        float d=a2/max(PI*denominator*denominator,1e-10);
        pdf=(1.0-chance)*nl/PI+chance*d*nh/max(4.0*abs(dot(view,h)),0.00001);
        throughput*=brdf(s,view,nextDirection)/max(pdf,1e-8);
        if(bounce>=2) {
            float survive=clamp(max(throughput.r,max(throughput.g,throughput.b)),0.05,0.95);
            if(randomValue()>survive) break;
            throughput/=survive;
        }
        origin=s.position+s.geometric*u_Trace.y*2.0; direction=nextDirection;
    }
    return clamp(radiance,vec3(0),vec3(u_Trace.z));
}
[[main]]
void path_fragment() {
    if(u_Frame.y>1.5) {
        // Geometry-aware reconstruction; filtering happens after, never inside, static accumulation.
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
        vec3 fallback=textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb;
        o_Color=vec4(weightSum>0.00001?sum/weightSum:fallback,1); return;
    }
    if(u_Frame.y>0.5) {
        vec4 normal=textureLod(sampler2D(u_Normal,u_Nearest),v_UV,0);
        vec3 position=textureLod(sampler2D(u_Position,u_Nearest),v_UV,0).xyz;
        vec3 center=textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb;
        if(dot(normal.xyz,normal.xyz)<0.01 || normal.w<0.15) { o_Color=vec4(center,1); return; }
        vec2 size=vec2(textureSize(sampler2D(u_History,u_Nearest),0));
        vec3 sum=vec3(0); float weights=0.0;
        for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
            vec2 uv=clamp(v_UV+vec2(x,y)/size,vec2(0),vec2(1));
            vec4 otherNormal=textureLod(sampler2D(u_Normal,u_Nearest),uv,0);
            vec3 otherPosition=textureLod(sampler2D(u_Position,u_Nearest),uv,0).xyz;
            if(dot(otherNormal.xyz,otherNormal.xyz)<0.01) continue;
            vec3 value=textureLod(sampler2D(u_History,u_Nearest),uv,0).rgb;
            float weight=exp(-float(x*x+y*y)*0.25)*pow(max(dot(normalize(normal.xyz),normalize(otherNormal.xyz)),0.0),32.0);
            weight*=exp(-abs(position.z-otherPosition.z)/max(0.015,position.z*0.005));
            weight*=exp(-abs(normal.w-otherNormal.w)*12.0);
            // Bounded anti-firefly weighting; raw sample accumulation remains unfiltered.
            weight/=sqrt(1.0+dot(value,vec3(0.2126,0.7152,0.0722)));
            sum+=value*weight; weights+=weight;
        }
        o_Color=vec4(weights>0.00001?sum/weights:center,1); return;
    }
    uvec2 pixel=uvec2(gl_FragCoord.xy);
    randomState=pixel.x*1973u+pixel.y*9277u+uint(u_Frame.x)*26699u+911u;
    vec3 color=vec3(0);
    for(int sampleIndex=0;sampleIndex<8;++sampleIndex) {
        if(sampleIndex>=int(u_Counts.z)) break;
        vec2 size=vec2(textureSize(sampler2D(u_History,u_Nearest),0));
        vec2 uv=v_UV+(vec2(randomValue(),randomValue())-0.5)/size;
        vec2 ndc=uv*vec2(2,-2)+vec2(-1,1);
        vec4 nearPoint=u_InverseProjection*vec4(ndc,0,1),farPoint=u_InverseProjection*vec4(ndc,1,1);
        vec3 viewOrigin=nearPoint.xyz/nearPoint.w;
        vec3 direction=normalize(mat3(u_InverseView)*(farPoint.xyz/farPoint.w-viewOrigin));
        vec3 origin=(u_InverseView*vec4(viewOrigin,1)).xyz;
        color+=path(origin,direction);
    }
    color/=u_Counts.z;
    if(u_Trace.w>0.0) color=mix(color,textureLod(sampler2D(u_History,u_Nearest),v_UV,0).rgb,u_Trace.w/(u_Trace.w+1.0));
    o_Color=vec4(color,1);
}
