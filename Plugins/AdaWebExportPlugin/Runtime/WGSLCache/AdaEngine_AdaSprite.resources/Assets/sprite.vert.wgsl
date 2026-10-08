// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOut {
  Color : vec4f,
  TexCoordinate : vec2f,
}

struct AE_GlobalView {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_ViewProjection : mat4x4f,
  /* @offset(128) */
  u_ViewMatrix : mat4x4f,
}

var<private> Output : VertexOut;

var<private> a_Color : vec4f;

var<private> a_TexCoordinate : vec2f;

@group(0) @binding(2) var<uniform> x_34 : AE_GlobalView;

var<private> a_Position : vec4f;

var<private> gl_Position : vec4f;

fn main_1() {
  Output.Color = a_Color;
  Output.TexCoordinate = a_TexCoordinate;
  gl_Position = (x_34.u_ViewProjection * a_Position);
  return;
}

struct main_out {
  @location(0)
  Output_1 : vec4f,
  @location(1)
  Output_2 : vec2f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn sprite_vertex(@location(1) a_Color_param : vec4f, @location(2) a_TexCoordinate_param : vec2f, @location(0) a_Position_param : vec4f) -> main_out {
  a_Color = a_Color_param;
  a_TexCoordinate = a_TexCoordinate_param;
  a_Position = a_Position_param;
  main_1();
  return main_out(Output.Color, Output.TexCoordinate, gl_Position);
}

