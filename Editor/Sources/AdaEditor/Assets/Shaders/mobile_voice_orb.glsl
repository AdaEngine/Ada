#version 450 core
#pragma stage : frag
#include <AdaEngine/UIShaderMaterial.frag>

// Ported from Sloppy Desktop Companion's DesktopOrb.metal. Keep the volume,
// ribbons, palette, bloom and edge fade identical to the companion Bubble.
layout (std140, binding = 0) uniform MobileVoiceOrbMaterial {
    vec4 u_Geometry;
    vec4 u_Style;
};

float orbHash(vec3 p) { p=fract(p*.3183099+vec3(.17,.31,.53)); p*=17.; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float orbNoise(vec3 p) {
  vec3 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
  return mix(mix(mix(orbHash(i),orbHash(i+vec3(1,0,0)),f.x),mix(orbHash(i+vec3(0,1,0)),orbHash(i+vec3(1,1,0)),f.x),f.y),
             mix(mix(orbHash(i+vec3(0,0,1)),orbHash(i+vec3(1,0,1)),f.x),mix(orbHash(i+vec3(0,1,1)),orbHash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
vec2 orbRotate(vec2 p, float a) { float c=cos(a),s=sin(a); return vec2(c*p.x+s*p.y,-s*p.x+c*p.y); }
vec4 mobileVoiceOrb(vec2 coordinates, vec2 resolution, float time, float level) {
  vec2 uv=(coordinates-.5*resolution)/min(resolution.x,resolution.y)*2.;
  float t=time*.23;
  float breath=1.+.025*sin(time*.8)+level*.105+level*.045;
  vec2 q=uv/(.70*breath);
  float r=length(q);
  vec3 light=vec3(0.);
  float a=atan(q.y,q.x);
  float halo=exp(-pow(r/1.03,4.))* .09 + exp(-pow((r-.94)/.24,2.))*.13;
  vec3 haloColor=mix(vec3(.20,.35,.75),vec3(.64,.54,.77),.5+.5*sin(a*2.-t));
  light+=haloColor*halo;
  // Integrate luminous flowing ribbons through a soft spherical volume.
  float depth=sqrt(max(0.,1.12-r*r));
  for(int i=0;i<20;i++) {
    float z=(-1.+2.*(float(i)+.5)/20.)*depth;
    vec3 p=vec3(q,z);
    p.xz=orbRotate(p.xz,t*.37);
    p.xy=orbRotate(p.xy,t*.20);
    float radius=length(p);
    float n=orbNoise(p*2.9+vec3(t*.55,-t*.38,t*.25));
    float n2=orbNoise(p*5.6-vec3(t*.2,t*.45,0.));
    float angle=atan(p.y,p.x);
    float flow=angle*4.+p.z*3.2+radius*2.8-t*1.35+(n-.5)*4.2;
    float ribbon=pow(.5+.5*sin(flow),5.);
    float secondary=pow(.5+.5*sin(angle*3.-p.z*4.5-t*.8+n2*3.),9.);
    float envelope=1.-smoothstep(.72,1.08+(n-.5)*.09,radius);
    float cloud=.22+.78*n;
  float density=(ribbon*.92+secondary*.32+.12)*envelope*cloud;
    float hue=.5+.5*sin(flow*.45+p.z*2.+t*.7+n*3.);
    vec3 blue=vec3(.055,.25,.96), cyan=vec3(.16,.88,1.02), pearl=vec3(.87,.77,.96);
    vec3 color=mix(blue,cyan,smoothstep(.15,.76,hue));
    color=mix(color,pearl,pow(.5+.5*sin(p.y*3.+p.z*2.+t*.9+n2*2.),6.)*.75);
    color=mix(color,vec3(.58,.38,1.),level*.23);
    light+=color*density*depth*.13*(1.+level*.95+level*.35);
  }
  // A diffuse luminous core and optical bloom, without a hard silhouette.
  float core=exp(-r*r*15.)*(.27+.09*sin(t*2.)+level*.2);
  light+=vec3(.39,.75,1.)*core;
  float veil=exp(-pow(r/.86,6.))*.12;
  light+=vec3(.10,.24,.72)*veil;
  float beamAngle=a+t*.6+.45*sin(r*3.-t)+.22*sin(a*3.+t);
  float beams=pow(.5+.5*sin(beamAngle*5.),4.);
  light+=vec3(.18,.66,.91)*beams*exp(-r*r*2.8)*(1.-smoothstep(.8,1.1,r))*.31;
  light=1.-exp(-light*3.4);
  float grain=(orbHash(vec3(coordinates,7.))-.5)*.018;
  light=max(vec3(0.),light+grain*min(1.,halo*3.+length(light)));
  float alpha=clamp(max(max(light.r,light.g),light.b)*1.3,0.,1.);
  // Fade both premultiplied color and alpha before reaching the canvas/ring edge.
  float edgeFade=1.-smoothstep(.68,1.,length(uv));
  return vec4(light,alpha)*edgeFade;
}

[[main]]
void mobile_voice_orb_fragment() {
    vec2 size = u_Geometry.xy;
    COLOR = mobileVoiceOrb(vec2(Input.UV.x, 1.0 - Input.UV.y) * size,
        size, u_Geometry.z, u_Geometry.w) * u_Style.x;
}
