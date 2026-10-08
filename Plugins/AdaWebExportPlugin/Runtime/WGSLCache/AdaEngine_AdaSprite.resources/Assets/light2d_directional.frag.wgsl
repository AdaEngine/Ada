// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct DirectionalLightData {
  /* @offset(0) */
  u_LightRGB_Energy : vec4f,
  /* @offset(16) */
  u_Flags : vec4f,
}

@group(0) @binding(2) var<uniform> x_13 : DirectionalLightData;

@group(0) @binding(0) var u_ShadowMask : texture_2d<f32>;

@group(0) @binding(1) var u_ShadowSampler : sampler;

var<private> v_UV : vec2f;

var<private> o_Color : vec4f;

fn main_1() {
  var rgb : vec3f;
  var m : f32;
  rgb = (x_13.u_LightRGB_Energy.xyz * x_13.u_LightRGB_Energy.w);
  if ((x_13.u_Flags.x > 0.5f)) {
    m = textureSample(u_ShadowMask, u_ShadowSampler, v_UV).x;
    rgb = (rgb * m);
  }
  o_Color = vec4f(rgb.x, rgb.y, rgb.z, 1.0f);
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn light2d_directional_frag(@location(0) v_UV_param : vec2f) -> main_out {
  v_UV = v_UV_param;
  main_1();
  return main_out(o_Color);
}

