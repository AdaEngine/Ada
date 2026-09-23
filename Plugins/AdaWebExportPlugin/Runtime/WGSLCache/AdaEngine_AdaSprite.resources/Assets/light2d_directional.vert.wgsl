// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

var<private> gl_VertexIndex : i32;

var<private> v_UV : vec2f;

var<private> gl_Position : vec4f;

fn main_1() {
  var vi : u32;
  var uv : vec2f;
  vi = bitcast<u32>(gl_VertexIndex);
  uv = (vec2f(f32((vi >> 1u)), f32((vi & 1u))) * 2.0f);
  let x_41 = ((uv * vec2f(2.0f, -2.0f)) + vec2f(-1.0f, 1.0f));
  gl_Position = vec4f(x_41.x, x_41.y, 0.0f, 1.0f);
  v_UV = uv;
  return;
}

struct main_out {
  @builtin(position)
  gl_Position : vec4f,
  @location(0)
  v_UV_1 : vec2f,
}

@vertex
fn light2d_directional_vert(@builtin(vertex_index) gl_VertexIndex_param : u32) -> main_out {
  gl_VertexIndex = bitcast<i32>(gl_VertexIndex_param);
  main_1();
  return main_out(gl_Position, v_UV);
}

