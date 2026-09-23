// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

var<private> o_Color : vec4f;

@group(0) @binding(0) var u_MainTexture : texture_2d<f32>;

@group(0) @binding(1) var u_MainSampler : sampler;

var<private> v_UV : vec2f;

fn main_1() {
  o_Color = textureSample(u_MainTexture, u_MainSampler, v_UV);
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn fullscreen_fragment(@location(0) v_UV_param : vec2f) -> main_out {
  v_UV = v_UV_param;
  main_1();
  return main_out(o_Color);
}

