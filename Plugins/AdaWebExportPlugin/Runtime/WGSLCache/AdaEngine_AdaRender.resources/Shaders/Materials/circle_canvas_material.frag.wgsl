// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct CircleCanvasMaterial {
  /* @offset(0) */
  u_Fade : f32,
  /* @offset(4) */
  u_Thickness : f32,
  /* @offset(16) */
  u_Color : vec4f,
}

struct VertexOut {
  WorldPosition : vec4f,
  WorldNormal : vec3f,
  UV : vec2f,
  VertexColor : vec4f,
}

@group(0) @binding(0) var<uniform> x_12 : CircleCanvasMaterial;

var<private> Input : VertexOut;

var<private> COLOR : vec4f;

fn main_1() {
  var fade : f32;
  var thickness : f32;
  var uv : vec2f;
  var dist : f32;
  var alpha : f32;
  var x_56 : bool;
  var x_57 : bool;
  fade = x_12.u_Fade;
  thickness = x_12.u_Thickness;
  uv = (Input.UV - vec2f(0.5f));
  dist = sqrt(dot((uv * 2.0f), (uv * 2.0f)));
  let x_47 = (dist > 1.0f);
  x_57 = x_47;
  if (!(x_47)) {
    x_56 = (dist < ((1.0f - thickness) - fade));
    x_57 = x_56;
  }
  if (x_57) {
    discard;
  }
  alpha = (1.0f - smoothstep((1.0f - fade), 1.0f, dist));
  alpha = (alpha * smoothstep(((1.0f - thickness) - fade), (1.0f - thickness), dist));
  COLOR = x_12.u_Color;
  COLOR.w = alpha;
  return;
}

struct main_out {
  @location(0)
  COLOR_1 : vec4f,
}

@fragment
fn circle_canvas_mesh_fragment(@location(0) Input_param : vec4f, @location(1) Input_param_1 : vec3f, @location(2) Input_param_2 : vec2f, @location(3) Input_param_3 : vec4f) -> main_out {
  Input.WorldPosition = Input_param;
  Input.WorldNormal = Input_param_1;
  Input.UV = Input_param_2;
  Input.VertexColor = Input_param_3;
  main_1();
  return main_out(COLOR);
}

