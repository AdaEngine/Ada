// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct Light2DCompositeData {
  /* @offset(0) */
  u_Modulate : vec4f,
}

@group(0) @binding(0) var u_Albedo : texture_2d<f32>;

@group(0) @binding(2) var u_Sampler : sampler;

var<private> v_UV : vec2f;

@group(0) @binding(1) var u_LightAccum : texture_2d<f32>;

@group(0) @binding(3) var<uniform> x_40 : Light2DCompositeData;

var<private> o_Color : vec4f;

fn main_1() {
  var albedo : vec4f;
  var addLight : vec3f;
  var lit : vec3f;
  albedo = textureSample(u_Albedo, u_Sampler, v_UV);
  addLight = textureSample(u_LightAccum, u_Sampler, v_UV).xyz;
  lit = ((albedo.xyz * x_40.u_Modulate.xyz) + (albedo.xyz * addLight));
  o_Color = vec4f(lit.x, lit.y, lit.z, albedo.w);
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn light2d_composite_frag(@location(0) v_UV_param : vec2f) -> main_out {
  v_UV = v_UV_param;
  main_1();
  return main_out(o_Color);
}

