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

var<private> v_Color : vec4f;

var<private> a_Color : vec4f;

var<private> v_TexCoordinate : vec2f;

var<private> a_TexCoordinate : vec2f;

var<private> v_GlassParams0 : vec4f;

var<private> a_GlassParams0 : vec4f;

var<private> v_GlassParams1 : vec4f;

var<private> a_GlassParams1 : vec4f;

var<private> v_GlassParams2 : vec4f;

var<private> a_GlassParams2 : vec4f;

var<private> v_GlassParams3 : vec4f;

var<private> a_GlassParams3 : vec4f;

var<private> v_GlassInfo0 : vec4f;

var<private> a_GlassInfo0 : vec4f;

var<private> v_GlassInfo1 : vec4f;

var<private> a_GlassInfo1 : vec4f;

@group(0) @binding(2) var<uniform> x_48 : AE_GlobalView;

var<private> a_Position : vec4f;

var<private> gl_Position : vec4f;

fn main_1() {
  v_Color = a_Color;
  v_TexCoordinate = a_TexCoordinate;
  v_GlassParams0 = a_GlassParams0;
  v_GlassParams1 = a_GlassParams1;
  v_GlassParams2 = a_GlassParams2;
  v_GlassParams3 = a_GlassParams3;
  v_GlassInfo0 = a_GlassInfo0;
  v_GlassInfo1 = a_GlassInfo1;
  gl_Position = (x_48.u_ViewProjection * a_Position);
  return;
}

struct main_out {
  @location(0)
  v_Color_1 : vec4f,
  @location(1)
  v_TexCoordinate_1 : vec2f,
  @location(2)
  v_GlassParams0_1 : vec4f,
  @location(3)
  v_GlassParams1_1 : vec4f,
  @location(4)
  v_GlassParams2_1 : vec4f,
  @location(5)
  v_GlassParams3_1 : vec4f,
  @location(6)
  v_GlassInfo0_1 : vec4f,
  @location(7)
  v_GlassInfo1_1 : vec4f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn glass_vertex(@location(1) a_Color_param : vec4f, @location(2) a_TexCoordinate_param : vec2f, @location(3) a_GlassParams0_param : vec4f, @location(4) a_GlassParams1_param : vec4f, @location(5) a_GlassParams2_param : vec4f, @location(6) a_GlassParams3_param : vec4f, @location(7) a_GlassInfo0_param : vec4f, @location(8) a_GlassInfo1_param : vec4f, @location(0) a_Position_param : vec4f) -> main_out {
  a_Color = a_Color_param;
  a_TexCoordinate = a_TexCoordinate_param;
  a_GlassParams0 = a_GlassParams0_param;
  a_GlassParams1 = a_GlassParams1_param;
  a_GlassParams2 = a_GlassParams2_param;
  a_GlassParams3 = a_GlassParams3_param;
  a_GlassInfo0 = a_GlassInfo0_param;
  a_GlassInfo1 = a_GlassInfo1_param;
  a_Position = a_Position_param;
  main_1();
  return main_out(v_Color, v_TexCoordinate, v_GlassParams0, v_GlassParams1, v_GlassParams2, v_GlassParams3, v_GlassInfo0, v_GlassInfo1, gl_Position);
}

