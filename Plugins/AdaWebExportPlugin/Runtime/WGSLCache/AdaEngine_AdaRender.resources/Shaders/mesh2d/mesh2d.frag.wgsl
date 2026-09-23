// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOut {
  WorldPosition : vec4f,
  WorldNormal : vec3f,
  UV : vec2f,
  VertexColor : vec4f,
}

var<private> COLOR : vec4f;

var<private> Input : VertexOut;

fn main_1() {
  COLOR = Input.VertexColor;
  if ((COLOR.w == 0.0f)) {
    discard;
  }
  return;
}

struct main_out {
  @location(0)
  COLOR_1 : vec4f,
}

@fragment
fn mesh_fragment(@location(0) Input_param : vec4f, @location(1) Input_param_1 : vec3f, @location(2) Input_param_2 : vec2f, @location(3) Input_param_3 : vec4f) -> main_out {
  Input.WorldPosition = Input_param;
  Input.WorldNormal = Input_param_1;
  Input.UV = Input_param_2;
  Input.VertexColor = Input_param_3;
  main_1();
  return main_out(COLOR);
}

