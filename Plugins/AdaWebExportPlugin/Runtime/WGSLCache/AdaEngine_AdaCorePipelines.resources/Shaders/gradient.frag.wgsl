// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct GradientUniform {
  /* @offset(0) */
  u_StartPoint : vec2f,
  /* @offset(8) */
  u_EndPoint : vec2f,
  /* @offset(16) */
  u_StopCount : i32,
  /* @offset(20) */
  u_Padding : i32,
  /* @offset(32) */
  u_StopColor0 : vec4f,
  /* @offset(48) */
  u_StopColor1 : vec4f,
  /* @offset(64) */
  u_StopColor2 : vec4f,
  /* @offset(80) */
  u_StopColor3 : vec4f,
  /* @offset(96) */
  u_StopColor4 : vec4f,
  /* @offset(112) */
  u_StopColor5 : vec4f,
  /* @offset(128) */
  u_StopColor6 : vec4f,
  /* @offset(144) */
  u_StopColor7 : vec4f,
  /* @offset(160) */
  u_StopColor8 : vec4f,
  /* @offset(176) */
  u_StopColor9 : vec4f,
  /* @offset(192) */
  u_StopColor10 : vec4f,
  /* @offset(208) */
  u_StopColor11 : vec4f,
  /* @offset(224) */
  u_StopColor12 : vec4f,
  /* @offset(240) */
  u_StopColor13 : vec4f,
  /* @offset(256) */
  u_StopColor14 : vec4f,
  /* @offset(272) */
  u_StopColor15 : vec4f,
  /* @offset(288) */
  u_StopLocations0 : vec4f,
  /* @offset(304) */
  u_StopLocations1 : vec4f,
  /* @offset(320) */
  u_StopLocations2 : vec4f,
  /* @offset(336) */
  u_StopLocations3 : vec4f,
}

struct VertexOut {
  TexCoordinate : vec2f,
}

@group(0) @binding(0) var<uniform> gradient : GradientUniform;

var<private> color : vec4f;

var<private> Input : VertexOut;

fn resolveGradientProgress_vf2_(uv : ptr<function, vec2f>) -> f32 {
  var axis : vec2f;
  var lengthSquared : f32;
  var projected : f32;
  axis = (gradient.u_EndPoint - gradient.u_StartPoint);
  lengthSquared = dot(axis, axis);
  if ((lengthSquared <= 0.00000099999999747524f)) {
    return 1.0f;
  }
  projected = (dot((*(uv) - gradient.u_StartPoint), axis) / lengthSquared);
  let x_184 = projected;
  return clamp(x_184, 0.0f, 1.0f);
}

fn stopColor_i1_(index : ptr<function, i32>) -> vec4f {
  let x_29 = *(index);
  switch(x_29) {
    case 14i: {
      let x_109 = gradient.u_StopColor14;
      return x_109;
    }
    case 13i: {
      let x_105 = gradient.u_StopColor13;
      return x_105;
    }
    case 12i: {
      let x_101 = gradient.u_StopColor12;
      return x_101;
    }
    case 11i: {
      let x_97 = gradient.u_StopColor11;
      return x_97;
    }
    case 10i: {
      let x_93 = gradient.u_StopColor10;
      return x_93;
    }
    case 9i: {
      let x_89 = gradient.u_StopColor9;
      return x_89;
    }
    case 8i: {
      let x_85 = gradient.u_StopColor8;
      return x_85;
    }
    case 7i: {
      let x_81 = gradient.u_StopColor7;
      return x_81;
    }
    case 6i: {
      let x_77 = gradient.u_StopColor6;
      return x_77;
    }
    case 5i: {
      let x_73 = gradient.u_StopColor5;
      return x_73;
    }
    case 4i: {
      let x_69 = gradient.u_StopColor4;
      return x_69;
    }
    case 3i: {
      let x_65 = gradient.u_StopColor3;
      return x_65;
    }
    case 2i: {
      let x_61 = gradient.u_StopColor2;
      return x_61;
    }
    case 1i: {
      let x_57 = gradient.u_StopColor1;
      return x_57;
    }
    case 0i: {
      let x_53 = gradient.u_StopColor0;
      return x_53;
    }
    default: {
      let x_113 = gradient.u_StopColor15;
      return x_113;
    }
  }
}

fn stopLocation_i1_(index_1 : ptr<function, i32>) -> f32 {
  if ((*(index_1) < 4i)) {
    let x_126 = gradient.u_StopLocations0[*(index_1)];
    return x_126;
  }
  if ((*(index_1) < 8i)) {
    let x_136 = gradient.u_StopLocations1[(*(index_1) - 4i)];
    return x_136;
  }
  if ((*(index_1) < 12i)) {
    let x_146 = gradient.u_StopLocations2[(*(index_1) - 8i)];
    return x_146;
  }
  let x_152 = gradient.u_StopLocations3[(*(index_1) - 12i)];
  return x_152;
}

fn resolveGradientColor_f1_(progress : ptr<function, f32>) -> vec4f {
  var stopCount : i32;
  var currentColor : vec4f;
  var param : i32;
  var currentLocation : f32;
  var param_1 : i32;
  var index_2 : i32;
  var nextColor : vec4f;
  var param_2 : i32;
  var nextLocation : f32;
  var param_3 : i32;
  var range : f32;
  var t : f32;
  stopCount = max(gradient.u_StopCount, 1i);
  param = 0i;
  let x_198 = stopColor_i1_(&(param));
  currentColor = x_198;
  param_1 = 0i;
  let x_201 = stopLocation_i1_(&(param_1));
  currentLocation = x_201;
  if ((stopCount == 1i)) {
    let x_206 = currentColor;
    return x_206;
  }
  index_2 = 1i;
  loop {
    if ((index_2 < stopCount)) {
    } else {
      break;
    }
    param_2 = index_2;
    let x_220 = stopColor_i1_(&(param_2));
    nextColor = x_220;
    param_3 = index_2;
    let x_224 = stopLocation_i1_(&(param_3));
    nextLocation = x_224;
    if ((*(progress) <= nextLocation)) {
      range = (nextLocation - currentLocation);
      if ((range <= 0.00000099999999747524f)) {
        let x_238 = nextColor;
        return x_238;
      }
      t = clamp(((*(progress) - currentLocation) / range), 0.0f, 1.0f);
      let x_247 = currentColor;
      let x_248 = nextColor;
      let x_249 = t;
      return mix(x_247, x_248, vec4f(x_249));
    }
    currentColor = nextColor;
    currentLocation = nextLocation;

    continuing {
      index_2 = (index_2 + 1i);
    }
  }
  let x_257 = currentColor;
  return x_257;
}

fn main_1() {
  var param_4 : vec2f;
  var param_5 : f32;
  param_4 = Input.TexCoordinate;
  let x_269 = resolveGradientProgress_vf2_(&(param_4));
  param_5 = x_269;
  let x_271 = resolveGradientColor_f1_(&(param_5));
  color = x_271;
  if ((color.w == 0.0f)) {
    discard;
  }
  return;
}

struct main_out {
  @location(0)
  color_1 : vec4f,
}

@fragment
fn linear_gradient_fragment(@location(0) Input_param : vec2f) -> main_out {
  Input.TexCoordinate = Input_param;
  main_1();
  return main_out(color);
}

