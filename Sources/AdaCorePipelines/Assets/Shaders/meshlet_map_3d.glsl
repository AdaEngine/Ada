#version 450 core
#pragma stage : vert
#include <AdaEngine/View.glsl>
layout(location=0) in vec4 a_PositionAndID;
layout(location=5) in vec4 a_Model0;
layout(location=6) in vec4 a_Model1;
layout(location=7) in vec4 a_Model2;
layout(location=8) in vec4 a_Model3;
layout(location=0) flat out vec3 v_Color;
layout(location=1) flat out float v_Orientation;
layout(location=2) out vec3 v_ViewPosition;
[[main]]
void meshlet_map_vertex() {
    mat4 model=mat4(a_Model0,a_Model1,a_Model2,a_Model3);
    vec4 worldPosition=model*vec4(a_PositionAndID.xyz,1);
    gl_Position=u_ViewProjection*worldPosition;
    v_ViewPosition=(u_ViewMatrix*worldPosition).xyz;
    v_Orientation=determinant(mat3(model))<0.0?-1.0:1.0;
    uint encodedID=uint(a_PositionAndID.w);
    uint level=encodedID>>20u;
    uint id=(encodedID&1048575u)+1u;
    id^=id>>16u; id*=2146121005u; id^=id>>15u; id*=2221713035u; id^=id>>16u;
    v_Color=vec3(0.2)+0.8*vec3(float(id&255u),float((id>>8u)&255u),float((id>>16u)&255u))/255.0;
    if(level>0u) {
        vec3 palette[6]=vec3[6](vec3(0.2,0.85,1.0),vec3(0.95,0.45,0.1),vec3(0.9,0.2,0.7),
            vec3(0.5,0.35,1.0),vec3(1.0,0.85,0.15),vec3(0.3,1.0,0.4));
        v_Color=mix(v_Color,palette[(level-1u)%6u],0.7);
    }
}
#version 450 core
#pragma stage : frag
layout(location=0) flat in vec3 v_Color;
layout(location=1) flat in float v_Orientation;
layout(location=2) in vec3 v_ViewPosition;
layout(binding=54) uniform MapFlags { vec4 u_MapFlags; };
layout(location=0) out vec4 o_Color;
layout(location=1) out vec4 o_Normal;
layout(location=2) out vec4 o_Position;
layout(location=3) out vec4 o_Indirect;
#ifdef MAP_RESPONSE
layout(location=4) out vec4 o_Response;
#endif
#ifdef MAP_SURFACE
#ifdef MAP_RESPONSE
layout(location=5) out vec4 o_Surface;
#else
layout(location=4) out vec4 o_Surface;
#endif
#endif
[[main]]
void meshlet_map_fragment() {
    vec3 geometricNormal=normalize(cross(dFdx(v_ViewPosition),dFdy(v_ViewPosition)));
    bool front=v_Orientation<0.0?!gl_FrontFacing:gl_FrontFacing;
    if(u_MapFlags.x<0.5&&!front) discard;
    o_Color=vec4(v_Color,1); o_Normal=vec4(geometricNormal,1); o_Position=vec4(v_ViewPosition,0); o_Indirect=vec4(0);
#ifdef MAP_RESPONSE
    o_Response=vec4(0);
#endif
#ifdef MAP_SURFACE
    o_Surface=vec4(0);
#endif
}
