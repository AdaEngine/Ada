// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct DirectionalShadowViewUniform {
  /* @offset(0) */
  u_ShadowViewProjection : mat4x4f,
}

var<private> a_Model0 : vec4f;

var<private> a_Model1 : vec4f;

var<private> a_Model2 : vec4f;

var<private> a_Model3 : vec4f;

@group(0) @binding(2) var<uniform> x_53 : DirectionalShadowViewUniform;

var<private> a_Position : vec3f;

var<private> gl_Position : vec4f;

fn main_1() {
  var model : mat4x4f;
  model = mat4x4f(vec4f(a_Model0.x, a_Model0.y, a_Model0.z, a_Model0.w), vec4f(a_Model1.x, a_Model1.y, a_Model1.z, a_Model1.w), vec4f(a_Model2.x, a_Model2.y, a_Model2.z, a_Model2.w), vec4f(a_Model3.x, a_Model3.y, a_Model3.z, a_Model3.w));
  gl_Position = ((x_53.u_ShadowViewProjection * model) * vec4f(a_Position.x, a_Position.y, a_Position.z, 1.0f));
  return;
}

struct main_out {
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn directional_shadow_3d_vertex(@location(5) a_Model0_param : vec4f, @location(6) a_Model1_param : vec4f, @location(7) a_Model2_param : vec4f, @location(8) a_Model3_param : vec4f, @location(0) a_Position_param : vec3f) -> main_out {
  a_Model0 = a_Model0_param;
  a_Model1 = a_Model1_param;
  a_Model2 = a_Model2_param;
  a_Model3 = a_Model3_param;
  a_Position = a_Position_param;
  main_1();
  return main_out(gl_Position);
}

