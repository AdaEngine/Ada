// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOutput {
  LocalPosition : vec2f,
  Thickness : f32,
  Fade : f32,
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

var<private> a_LocalPosition : vec2f;

var<private> a_Thickness : f32;

var<private> a_Color : vec4f;

var<private> a_Fade : f32;

@group(0) @binding(2) var<uniform> x_44 : AE_GlobalView;

var<private> a_WorldPosition : vec3f;

var<private> gl_Position : vec4f;

fn main_1() {
  Output.LocalPosition = a_LocalPosition;
  Output.Thickness = a_Thickness;
  Output.Color = a_Color;
  Output.Fade = a_Fade;
  gl_Position = (x_44.u_ViewProjection * vec4f(a_WorldPosition.x, a_WorldPosition.y, a_WorldPosition.z, 1.0f));
  return;
}

struct main_out {
  @location(0)
  Output_1 : vec2f,
  @location(1)
  Output_2 : f32,
  @location(2)
  Output_3 : f32,
  @location(3)
  Output_4 : vec4f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn circle_vertex(@location(1) a_LocalPosition_param : vec2f, @location(2) a_Thickness_param : f32, @location(4) a_Color_param : vec4f, @location(3) a_Fade_param : f32, @location(0) a_WorldPosition_param : vec3f) -> main_out {
  a_LocalPosition = a_LocalPosition_param;
  a_Thickness = a_Thickness_param;
  a_Color = a_Color_param;
  a_Fade = a_Fade_param;
  a_WorldPosition = a_WorldPosition_param;
  main_1();
  return main_out(Output.LocalPosition, Output.Thickness, Output.Fade, Output.Color, gl_Position);
}

