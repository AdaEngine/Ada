// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct PointLightUBO {
  /* @offset(0) */
  u_InvViewProjection : mat4x4f,
  /* @offset(64) */
  u_LightXY_Radius : vec4f,
  /* @offset(80) */
  u_LightRGB_Energy : vec4f,
  /* @offset(96) */
  u_Flags : vec4f,
}

var<private> v_UV : vec2f;

@group(0) @binding(4) var<uniform> x_27 : PointLightUBO;

@group(0) @binding(0) var u_ShadowMask : texture_2d<f32>;

@group(0) @binding(1) var u_ShadowSampler : sampler;

@group(0) @binding(2) var u_Cookie : texture_2d<f32>;

@group(0) @binding(3) var u_CookieSampler : sampler;

var<private> o_Color : vec4f;

fn main_1() {
  var ndc : vec2f;
  var world4 : vec4f;
  var world : vec2f;
  var lp : vec2f;
  var radius : f32;
  var d : f32;
  var atten : f32;
  var rgb : vec3f;
  var m : f32;
  var cookie : vec3f;
  ndc = ((v_UV * vec2f(2.0f, -2.0f)) + vec2f(-1.0f, 1.0f));
  world4 = (x_27.u_InvViewProjection * vec4f(ndc.x, ndc.y, 0.0f, 1.0f));
  world = (world4.xy / vec2f(max(world4.w, 0.00000999999974737875f)));
  lp = x_27.u_LightXY_Radius.xy;
  radius = max(x_27.u_LightXY_Radius.z, 0.00100000004749745131f);
  d = distance(world, lp);
  atten = (1.0f - smoothstep(0.0f, radius, d));
  rgb = ((x_27.u_LightRGB_Energy.xyz * x_27.u_LightRGB_Energy.w) * atten);
  if ((x_27.u_Flags.x > 0.5f)) {
    m = textureSample(u_ShadowMask, u_ShadowSampler, v_UV).x;
    rgb = (rgb * m);
  }
  if ((x_27.u_Flags.y > 0.5f)) {
    cookie = textureSample(u_Cookie, u_CookieSampler, v_UV).xyz;
    rgb = (rgb * cookie);
  }
  o_Color = vec4f(rgb.x, rgb.y, rgb.z, 1.0f);
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn light2d_point_frag(@location(0) v_UV_param : vec2f) -> main_out {
  v_UV = v_UV_param;
  main_1();
  return main_out(o_Color);
}

