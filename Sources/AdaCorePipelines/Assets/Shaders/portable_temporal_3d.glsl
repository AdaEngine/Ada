#version 450 core
#pragma stage : vert
layout(location=0) out vec2 v_UV;
[[main]]
void fullscreen_vertex() {
    vec2 uv=vec2(float(gl_VertexIndex>>1u),float(gl_VertexIndex&1u))*2.0;
    gl_Position=vec4(uv*vec2(2.0,-2.0)+vec2(-1.0,1.0),0.0,1.0); v_UV=uv;
}
#version 450 core
#pragma stage : frag
layout(location=0) in vec2 v_UV;
layout(location=0) out vec4 o_Color;
layout(location=1) out vec4 o_History;
layout(location=2) out float o_Depth;
layout(binding=0) uniform texture2D u_Color;
layout(binding=1) uniform texture2D u_Depth;
layout(binding=2) uniform texture2D u_Motion;
layout(binding=3) uniform texture2D u_Reactive;
layout(binding=4) uniform texture2D u_History;
layout(binding=5) uniform texture2D u_HistoryDepth;
layout(binding=6) uniform sampler u_Linear;
layout(binding=7) uniform sampler u_Nearest;
layout(binding=8) uniform PortableTemporalConstants { vec4 u_Parameters; };
vec3 toYCoCg(vec3 c) { return vec3(dot(c,vec3(0.25,0.5,0.25)),c.r-c.b,c.g-(c.r+c.b)*0.5); }
vec3 toRGB(vec3 c) { return vec3(c.x+c.y*0.5-c.z*0.5,c.x+c.z*0.5,c.x-c.y*0.5-c.z*0.5); }
[[main]]
void temporal_fragment() {
    ivec2 size=textureSize(sampler2D(u_Color,u_Linear),0);
    vec2 texel=1.0/vec2(size), uv=clamp(v_UV+u_Parameters.xy,texel*0.5,1.0-texel*0.5);
    ivec2 center=clamp(ivec2(uv*vec2(size)),ivec2(0),size-1), selected=center;
    float closest=1.0;
    vec3 low=vec3(1e20),high=vec3(-1e20);
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        ivec2 pixel=clamp(center+ivec2(x,y),ivec2(0),size-1);
        vec3 color=toYCoCg(texelFetch(sampler2D(u_Color,u_Nearest),pixel,0).rgb);
        low=min(low,color); high=max(high,color);
        float d=texelFetch(sampler2D(u_Depth,u_Nearest),pixel,0).r;
        if(d<closest) { closest=d; selected=pixel; }
    }
    vec4 motion=texelFetch(sampler2D(u_Motion,u_Nearest),selected,0);
    vec2 previousUV=v_UV+motion.xy;
    float currentDepth=texelFetch(sampler2D(u_Depth,u_Nearest),center,0).r;
    ivec2 historySize=textureSize(sampler2D(u_History,u_Linear),0);
    ivec2 historyPixel=clamp(ivec2(previousUV*vec2(historySize)),ivec2(0),historySize-1);
    float oldDepth=texelFetch(sampler2D(u_HistoryDepth,u_Nearest),historyPixel,0).r;
    bool inside=all(greaterThan(previousUV,vec2(0.0)))&&all(lessThan(previousUV,vec2(1.0)));
    bool valid=u_Parameters.z<0.5&&inside&&motion.w>0.5&&abs(oldDepth-motion.z)<max(0.00015,abs(dFdx(currentDepth))+abs(dFdy(currentDepth)));
    vec3 current=texture(sampler2D(u_Color,u_Linear),uv).rgb;
    if(!valid) { o_Color=vec4(current,1.0); o_History=o_Color; o_Depth=currentDepth; return; }
    vec3 history=toYCoCg(texture(sampler2D(u_History,u_Linear),previousUV).rgb);
    history=clamp(history,low,high);
    float reactive=texture(sampler2D(u_Reactive,u_Nearest),uv).r;
    float speed=length(motion.xy*vec2(size));
    float weight=valid?mix(0.92,0.55,clamp(speed/32.0,0.0,1.0))*(1.0-reactive):0.0;
    // Luminance compression prevents bright emitters from dominating the accumulated frame.
    vec3 previous=max(toRGB(history),vec3(0.0));
    float a=weight/(1.0+max(max(previous.r,previous.g),previous.b));
    float b=(1.0-weight)/(1.0+max(max(current.r,current.g),current.b));
    vec3 result=(previous*a+current*b)/max(a+b,0.000001);
    o_Color=vec4(result,1.0); o_History=o_Color; o_Depth=currentDepth;
}
