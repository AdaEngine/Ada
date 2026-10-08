// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

var<private> o_Depth : vec4f;

var<private> gl_FragCoord : vec4f;

fn main_1() {
  o_Depth = vec4f(gl_FragCoord.z);
  return;
}

struct main_out {
  @location(0)
  o_Depth_1 : vec4f,
}

@fragment
fn directional_shadow_3d_fragment(@builtin(position) gl_FragCoord_param : vec4f) -> main_out {
  gl_FragCoord = gl_FragCoord_param;
  main_1();
  return main_out(o_Depth);
}

