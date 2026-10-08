// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOutput {
  LocalPosition : vec2f,
  Thickness : f32,
  Fade : f32,
  Color : vec4f,
}

var<private> Input : VertexOutput;

var<private> color : vec4f;

fn main_1() {
  var fade : f32;
  var dist : f32;
  var alpha : f32;
  var x_42 : bool;
  var x_43 : bool;
  fade = Input.Fade;
  dist = sqrt(dot(Input.LocalPosition, Input.LocalPosition));
  let x_31 = (dist > 1.0f);
  x_43 = x_31;
  if (!(x_31)) {
    x_42 = (dist < ((1.0f - Input.Thickness) - fade));
    x_43 = x_42;
  }
  if (x_43) {
    discard;
  }
  alpha = (1.0f - smoothstep((1.0f - fade), 1.0f, dist));
  alpha = (alpha * smoothstep(((1.0f - Input.Thickness) - fade), (1.0f - Input.Thickness), dist));
  color = Input.Color;
  color.w = (color.w * alpha);
  return;
}

struct main_out {
  @location(0)
  color_1 : vec4f,
}

@fragment
fn circle_fragment(@location(0) Input_param : vec2f, @location(1) Input_param_1 : f32, @location(2) Input_param_2 : f32, @location(3) Input_param_3 : vec4f) -> main_out {
  Input.LocalPosition = Input_param;
  Input.Thickness = Input_param_1;
  Input.Fade = Input_param_2;
  Input.Color = Input_param_3;
  main_1();
  return main_out(color);
}

