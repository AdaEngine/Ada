// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct AE_GlobalView {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_ViewProjection : mat4x4f,
  /* @offset(128) */
  u_ViewMatrix : mat4x4f,
}

var<private> v_ForegroundColor : vec4f;

var<private> a_ForegroundColor : vec4f;

var<private> v_OutlineColor : vec4f;

var<private> a_OutlineColor : vec4f;

var<private> v_OutlineWidth : f32;

var<private> a_OutlineWidth : f32;

var<private> v_TexCoordinate : vec2f;

var<private> a_TexCoordinate : vec2f;

@group(0) @binding(2) var<uniform> x_38 : AE_GlobalView;

var<private> a_Position : vec4f;

var<private> gl_Position : vec4f;

fn main_1() {
  v_ForegroundColor = a_ForegroundColor;
  v_OutlineColor = a_OutlineColor;
  v_OutlineWidth = a_OutlineWidth;
  v_TexCoordinate = a_TexCoordinate;
  gl_Position = (x_38.u_ViewProjection * a_Position);
  return;
}

struct main_out {
  @location(0)
  v_ForegroundColor_1 : vec4f,
  @location(1)
  v_OutlineColor_1 : vec4f,
  @location(2)
  v_OutlineWidth_1 : f32,
  @location(3)
  v_TexCoordinate_1 : vec2f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn text_vertex(@location(1) a_ForegroundColor_param : vec4f, @location(2) a_OutlineColor_param : vec4f, @location(3) a_OutlineWidth_param : f32, @location(4) a_TexCoordinate_param : vec2f, @location(0) a_Position_param : vec4f) -> main_out {
  a_ForegroundColor = a_ForegroundColor_param;
  a_OutlineColor = a_OutlineColor_param;
  a_OutlineWidth = a_OutlineWidth_param;
  a_TexCoordinate = a_TexCoordinate_param;
  a_Position = a_Position_param;
  main_1();
  return main_out(v_ForegroundColor, v_OutlineColor, v_OutlineWidth, v_TexCoordinate, gl_Position);
}

