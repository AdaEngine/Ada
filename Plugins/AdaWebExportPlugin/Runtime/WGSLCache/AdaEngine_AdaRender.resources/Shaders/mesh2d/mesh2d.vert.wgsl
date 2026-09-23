// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct AE_Mesh2dUniform {
  /* @offset(0) */
  u_MeshModel : mat4x4f,
  /* @offset(64) */
  u_MeshInverseTransposeModel : mat4x4f,
}

struct VertexOut {
  WorldPosition : vec4f,
  WorldNormal : vec3f,
  UV : vec2f,
  VertexColor : vec4f,
}

struct AE_GlobalView {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_ViewProjection : mat4x4f,
  /* @offset(128) */
  u_ViewMatrix : mat4x4f,
}

@group(0) @binding(3) var<uniform> x_29 : AE_Mesh2dUniform;

var<private> Output : VertexOut;

var<private> a_Position : vec3f;

var<private> a_Normal : vec3f;

var<private> a_UV : vec2f;

var<private> a_VertexColor : vec4f;

@group(0) @binding(2) var<uniform> x_107 : AE_GlobalView;

var<private> gl_Position : vec4f;

fn Mesh2dPositionLocalToWorld_mf44_vf4_(model : ptr<function, mat4x4f>, vertex_position : ptr<function, vec4f>) -> vec4f {
  let x_22 = *(model);
  let x_23 = *(vertex_position);
  return (x_22 * x_23);
}

fn Mesh2dNormalLocalToWorld_vf3_(vertex_normal : ptr<function, vec3f>) -> vec3f {
  let x_36 = x_29.u_MeshInverseTransposeModel[0i].xyz;
  let x_39 = x_29.u_MeshInverseTransposeModel[1i].xyz;
  let x_43 = x_29.u_MeshInverseTransposeModel[2i].xyz;
  let x_60 = *(vertex_normal);
  return (mat3x3f(vec3f(x_36.x, x_36.y, x_36.z), vec3f(x_39.x, x_39.y, x_39.z), vec3f(x_43.x, x_43.y, x_43.z)) * x_60);
}

fn main_1() {
  var param : mat4x4f;
  var param_1 : vec4f;
  var param_2 : vec3f;
  let x_70 = a_Position;
  param = x_29.u_MeshModel;
  param_1 = vec4f(x_70.x, x_70.y, x_70.z, 1.0f);
  let x_80 = Mesh2dPositionLocalToWorld_mf44_vf4_(&(param), &(param_1));
  Output.WorldPosition = x_80;
  param_2 = a_Normal;
  let x_86 = Mesh2dNormalLocalToWorld_vf3_(&(param_2));
  Output.WorldNormal = x_86;
  Output.UV = a_UV;
  Output.VertexColor = a_VertexColor;
  gl_Position = (x_107.u_ViewProjection * Output.WorldPosition);
  return;
}

struct main_out {
  @location(0)
  Output_1 : vec4f,
  @location(1)
  Output_2 : vec3f,
  @location(2)
  Output_3 : vec2f,
  @location(3)
  Output_4 : vec4f,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn mesh_vertex(@location(0) a_Position_param : vec3f, @location(1) a_Normal_param : vec3f, @location(2) a_UV_param : vec2f, @location(3) a_VertexColor_param : vec4f) -> main_out {
  a_Position = a_Position_param;
  a_Normal = a_Normal_param;
  a_UV = a_UV_param;
  a_VertexColor = a_VertexColor_param;
  main_1();
  return main_out(Output.WorldPosition, Output.WorldNormal, Output.UV, Output.VertexColor, gl_Position);
}

