// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOutput {
  Color : vec4f,
}

struct AE_GlobalView {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_ViewProjection : mat4x4f,
  /* @offset(128) */
  u_ViewMatrix : mat4x4f,
}

var<private> Output : VertexOutput;

var<private> a_Color : vec4f;

@group(0) @binding(2) var<uniform> x_27 : AE_GlobalView;

var<private> a_Position : vec3f;

var<private> a_LineWidth : f32;

var<private> gl_Position : vec4f;

fn main_1() {
  Output.Color = a_Color;
  gl_Position = (x_27.u_ViewProjection * vec4f(a_Position.x, a_Position.y, a_Position.z, 1.0f));
  return;
}

struct main_out {
  @location(0)
  Output_1 : vec4f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn line_vertex(@location(1) a_Color_param : vec4f, @location(0) a_Position_param : vec3f, @location(2) a_LineWidth_param : f32) -> main_out {
  a_Color = a_Color_param;
  a_Position = a_Position_param;
  a_LineWidth = a_LineWidth_param;
  main_1();
  return main_out(Output.Color, gl_Position);
}

