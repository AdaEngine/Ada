// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOut {
  Color : vec4f,
  TexCoordinate : vec2f,
}

var<private> color : vec4f;

@group(0) @binding(0) var u_Texture : texture_2d<f32>;

@group(0) @binding(1) var u_TextureSampler : sampler;

var<private> Input : VertexOut;

fn main_1() {
  color = (textureSample(u_Texture, u_TextureSampler, Input.TexCoordinate) * Input.Color);
  if ((color.w == 0.0f)) {
    discard;
  }
  return;
}

struct main_out {
  @location(0)
  color_1 : vec4f,
}

@fragment
fn quad_fragment(@location(0) Input_param : vec4f, @location(1) Input_param_1 : vec2f) -> main_out {
  Input.Color = Input_param;
  Input.TexCoordinate = Input_param_1;
  main_1();
  return main_out(color);
}

