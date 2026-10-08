// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct Environment3DUniform {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_InverseProjection : mat4x4f,
  /* @offset(128) */
  u_InverseView : mat4x4f,
  /* @offset(192) */
  u_ZenithColor : vec4f,
  /* @offset(208) */
  u_HorizonColor : vec4f,
  /* @offset(224) */
  u_GroundColor : vec4f,
  /* @offset(240) */
  u_ClearColor : vec4f,
  /* @offset(256) */
  u_Reflection : vec4f,
  /* @offset(272) */
  u_ReflectionQuality : vec4f,
  /* @offset(288) */
  u_EnvironmentFlags : vec4f,
  /* @offset(304) */
  u_Starfield : vec4f,
}

@group(0) @binding(4) var<uniform> x_143 : Environment3DUniform;

@group(0) @binding(5) var u_EnvironmentTexture : texture_2d<f32>;

@group(0) @binding(3) var u_LinearSampler : sampler;

@group(0) @binding(0) var u_SceneColor : texture_2d<f32>;

@group(0) @binding(2) var u_ViewPositionMetallic : texture_2d<f32>;

@group(0) @binding(1) var u_NormalRoughness : texture_2d<f32>;

var<private> v_UV : vec2f;

var<private> o_Color : vec4f;

fn srgbToLinear_vf3_(value : ptr<function, vec3f>) -> vec3f {
  let x_47 = *(value);
  let x_51 = *(value);
  let x_63 = *(value);
  return mix((x_47 / vec3f(12.9200000762939453125f)), pow(((x_51 + vec3f(0.05499999970197677612f)) / vec3f(1.05499994754791259766f)), vec3f(2.40000009536743164062f)), step(vec3f(0.04044999927282333374f), x_63));
}

fn proceduralSky_vf3_(direction : ptr<function, vec3f>) -> vec3f {
  var height : f32;
  var horizonBlend : f32;
  var hemisphere : vec3f;
  var x_136 : vec3f;
  var sky : vec3f;
  var longitude : f32;
  var latitude : f32;
  var gridSize : vec2f;
  var gridPosition : vec2f;
  var cell : vec2f;
  var local : vec2f;
  var hashInput : vec3f;
  var existence : f32;
  var offset_1 : vec2f;
  var distanceToStar : f32;
  var threshold : f32;
  var starExists : f32;
  var star : f32;
  var glow : f32;
  var warm : vec3f;
  var cool : vec3f;
  var starColor : vec3f;
  height = clamp((*(direction)).y, -1.0f, 1.0f);
  horizonBlend = pow(abs(height), 0.55000001192092895508f);
  if ((height >= 0.0f)) {
    x_136 = x_143.u_ZenithColor.xyz;
  } else {
    x_136 = x_143.u_GroundColor.xyz;
  }
  hemisphere = x_136;
  sky = mix(x_143.u_HorizonColor.xyz, hemisphere, vec3f(horizonBlend));
  if ((x_143.u_EnvironmentFlags.w < 0.5f)) {
    let x_174 = sky;
    return x_174;
  }
  longitude = ((atan2((*(direction)).z, (*(direction)).x) / 6.28318548202514648438f) + 0.5f);
  latitude = ((asin(clamp((*(direction)).y, -1.0f, 1.0f)) / 3.14159274101257324219f) + 0.5f);
  gridSize = vec2f(220.0f, 110.0f);
  gridPosition = (vec2f(longitude, latitude) * gridSize);
  cell = floor(gridPosition);
  local = fract(gridPosition);
  hashInput = vec3f(cell.x, cell.y, x_143.u_Starfield.w);
  hashInput = fract((hashInput * vec3f(0.10310000181198120117f, 0.10300000011920928955f, 0.09730000048875808716f)));
  hashInput = (hashInput + vec3f(dot(hashInput, (hashInput.yzx + vec3f(33.3300018310546875f)))));
  existence = fract(((hashInput.x + hashInput.y) * hashInput.z));
  offset_1 = vec2f(fract(((existence * 17.1700000762939453125f) + hashInput.x)), fract(((existence * 31.729999542236328125f) + hashInput.y)));
  distanceToStar = length(((local - offset_1) / vec2f(max(x_143.u_Starfield.z, 0.10000000149011611938f))));
  threshold = mix(0.99800002574920654297f, 0.72000002861022949219f, x_143.u_Starfield.x);
  starExists = step(threshold, existence);
  star = (smoothstep(0.10999999940395355225f, 0.0f, distanceToStar) * starExists);
  glow = ((smoothstep(0.41999998688697814941f, 0.0f, distanceToStar) * starExists) * 0.21999999880790710449f);
  warm = vec3f(1.0f, 0.72000002861022949219f, 0.46000000834465026855f);
  cool = vec3f(0.57999998331069946289f, 0.75999999046325683594f, 1.0f);
  starColor = mix(warm, cool, vec3f(fract((existence * 47.0f))));
  let x_313 = sky;
  let x_314 = starColor;
  let x_315 = star;
  let x_316 = glow;
  let x_320 = x_143.u_Starfield.y;
  return (x_313 + ((x_314 * (x_315 + x_316)) * x_320));
}

fn sampleSky_vf3_(viewDirection : ptr<function, vec3f>) -> vec3f {
  var param_2 : vec3f;
  var worldDirection : vec3f;
  var uv_2 : vec2f;
  var textureColor : vec3f;
  var param_3 : vec3f;
  var param_4 : vec3f;
  var param_5 : vec3f;
  if ((x_143.u_EnvironmentFlags.x < 0.5f)) {
    param_2 = x_143.u_ClearColor.xyz;
    let x_335 = srgbToLinear_vf3_(&(param_2));
    return x_335;
  }
  let x_342 = *(viewDirection);
  worldDirection = normalize(((x_143.u_InverseView * vec4f(x_342.x, x_342.y, x_342.z, 0.0f))).xyz);
  if ((x_143.u_EnvironmentFlags.y > 0.5f)) {
    uv_2 = vec2f(((atan2(worldDirection.z, worldDirection.x) / 6.28318548202514648438f) + 0.5f), ((asin(clamp(worldDirection.y, -1.0f, 1.0f)) / 3.14159274101257324219f) + 0.5f));
    textureColor = textureSample(u_EnvironmentTexture, u_LinearSampler, uv_2).xyz;
    param_3 = textureColor;
    let x_386 = srgbToLinear_vf3_(&(param_3));
    let x_388 = x_143.u_EnvironmentFlags.z;
    return (x_386 * x_388);
  }
  param_4 = worldDirection;
  let x_393 = proceduralSky_vf3_(&(param_4));
  param_5 = x_393;
  let x_395 = srgbToLinear_vf3_(&(param_5));
  let x_397 = x_143.u_EnvironmentFlags.z;
  return (x_395 * x_397);
}

fn acesToneMap_vf3_(value_2 : ptr<function, vec3f>) -> vec3f {
  let x_88 = *(value_2);
  let x_90 = *(value_2);
  let x_96 = *(value_2);
  let x_98 = *(value_2);
  return clamp(((x_88 * ((x_90 * 2.50999999046325683594f) + vec3f(0.02999999932944774628f))) / ((x_96 * ((x_98 * 2.43000006675720214844f) + vec3f(0.58999997377395629883f))) + vec3f(0.14000000059604644775f))), vec3f(0.0f), vec3f(1.0f));
}

fn linearToSrgb_vf3_(value_1 : ptr<function, vec3f>) -> vec3f {
  *(value_1) = max(*(value_1), vec3f());
  let x_72 = *(value_1);
  let x_74 = *(value_1);
  let x_83 = *(value_1);
  return mix((x_72 * 12.9200000762939453125f), ((pow(x_74, vec3f(0.4166666567325592041f)) * 1.05499994754791259766f) - vec3f(0.05499999970197677612f)), step(vec3f(0.00313080009073019028f), x_83));
}

fn presentColor_vf3_(linearColor : ptr<function, vec3f>) -> vec3f {
  var param : vec3f;
  var param_1 : vec3f;
  param = *(linearColor);
  let x_116 = acesToneMap_vf3_(&(param));
  param_1 = x_116;
  let x_118 = linearToSrgb_vf3_(&(param_1));
  return x_118;
}

const x_403 = vec2f(1.0f);

fn traceReflection_vf3_vf3_vf2_(origin : ptr<function, vec3f>, direction_1 : ptr<function, vec3f>, hitUV : ptr<function, vec2f>) -> bool {
  var ray : vec3f;
  var step_1 : i32;
  var clip : vec4f;
  var uv_3 : vec2f;
  var scenePosition : vec3f;
  var rayDepth : f32;
  var sceneDepth : f32;
  ray = (*(origin) + (*(direction_1) * x_143.u_Reflection.w));
  step_1 = 0i;
  loop {
    var x_572 : bool;
    var x_573 : bool;
    if ((step_1 < 64i)) {
    } else {
      break;
    }
    if ((step_1 >= i32(x_143.u_ReflectionQuality.x))) {
      break;
    }
    ray = (ray + (*(direction_1) * x_143.u_Reflection.z));
    if ((distance(ray, *(origin)) > x_143.u_Reflection.y)) {
      break;
    }
    clip = (x_143.u_Projection * vec4f(ray.x, ray.y, ray.z, 1.0f));
    if ((clip.w <= 0.0f)) {
      break;
    }
    uv_3 = (clip.xy / vec2f(clip.w));
    uv_3 = ((uv_3 * vec2f(0.5f, -0.5f)) + vec2f(0.5f));
    let x_566 = any((uv_3 <= vec2f()));
    x_573 = x_566;
    if (!(x_566)) {
      x_572 = any((uv_3 >= x_403));
      x_573 = x_572;
    }
    if (x_573) {
      break;
    }
    var x_612 : bool;
    var x_613 : bool;
    scenePosition = textureSample(u_ViewPositionMetallic, u_LinearSampler, uv_3).xyz;
    if ((length(scenePosition) > 0.00009999999747378752f)) {
      rayDepth = -(ray.z);
      sceneDepth = -(scenePosition.z);
      let x_604 = (rayDepth >= (sceneDepth - x_143.u_Reflection.w));
      x_613 = x_604;
      if (x_604) {
        x_612 = (rayDepth <= (sceneDepth + x_143.u_Reflection.w));
        x_613 = x_612;
      }
      if (x_613) {
        *(hitUV) = uv_3;
        return true;
      }
    }

    continuing {
      step_1 = (step_1 + 1i);
    }
  }
  return false;
}

fn blurredScene_vf2_f1_(uv_1 : ptr<function, vec2f>, roughness : ptr<function, f32>) -> vec3f {
  var radius : vec2f;
  var center : vec3f;
  radius = vec2f(((0.01200000010430812836f * *(roughness)) * *(roughness)));
  center = (textureSample(u_SceneColor, u_LinearSampler, *(uv_1)).xyz * 0.40000000596046447754f);
  center = (center + (textureSample(u_SceneColor, u_LinearSampler, (*(uv_1) + vec2f(radius.x, 0.0f))).xyz * 0.15000000596046447754f));
  center = (center + (textureSample(u_SceneColor, u_LinearSampler, (*(uv_1) - vec2f(radius.x, 0.0f))).xyz * 0.15000000596046447754f));
  center = (center + (textureSample(u_SceneColor, u_LinearSampler, (*(uv_1) + vec2f(0.0f, radius.y))).xyz * 0.15000000596046447754f));
  center = (center + (textureSample(u_SceneColor, u_LinearSampler, (*(uv_1) - vec2f(0.0f, radius.y))).xyz * 0.15000000596046447754f));
  let x_488 = center;
  return x_488;
}

fn edgeVisibility_vf2_(uv : ptr<function, vec2f>) -> f32 {
  var edge : vec2f;
  edge = min(*(uv), (x_403 - *(uv)));
  let x_409 = x_143.u_ReflectionQuality.z;
  let x_411 = edge.x;
  let x_413 = edge.y;
  return smoothstep(0.0f, x_409, min(x_411, x_413));
}

fn main_1() {
  var normalRoughness : vec4f;
  var positionMetallic : vec4f;
  var ndc : vec2f;
  var viewFar : vec4f;
  var viewRay : vec3f;
  var param_6 : vec3f;
  var param_7 : vec3f;
  var baseColor : vec3f;
  var normal : vec3f;
  var roughness_1 : f32;
  var metallic : f32;
  var viewDirection_1 : vec3f;
  var reflectionDirection : vec3f;
  var environment : vec3f;
  var param_8 : vec3f;
  var reflectedColor : vec3f;
  var visibility : f32;
  var hitUV_1 : vec2f;
  var param_9 : vec3f;
  var param_10 : vec3f;
  var param_11 : vec2f;
  var param_12 : vec2f;
  var param_13 : f32;
  var param_14 : vec2f;
  var fresnel : f32;
  var reflectivity : f32;
  var ambient : vec3f;
  var param_15 : vec3f;
  var reflectionResult : vec3f;
  var param_16 : vec3f;
  var x_650 : bool;
  var x_651 : bool;
  normalRoughness = textureSample(u_NormalRoughness, u_LinearSampler, v_UV);
  positionMetallic = textureSample(u_ViewPositionMetallic, u_LinearSampler, v_UV);
  let x_643 = (length(normalRoughness.xyz) < 0.10000000149011611938f);
  x_651 = x_643;
  if (!(x_643)) {
    x_650 = (length(positionMetallic.xyz) < 0.00009999999747378752f);
    x_651 = x_650;
  }
  if (x_651) {
    ndc = vec2f(((v_UV.x * 2.0f) - 1.0f), (1.0f - (v_UV.y * 2.0f)));
    viewFar = (x_143.u_InverseProjection * vec4f(ndc.x, ndc.y, 1.0f, 1.0f));
    viewRay = normalize((viewFar.xyz / vec3f(viewFar.w)));
    param_6 = viewRay;
    let x_686 = sampleSky_vf3_(&(param_6));
    param_7 = x_686;
    let x_688 = presentColor_vf3_(&(param_7));
    o_Color = vec4f(x_688.x, x_688.y, x_688.z, 1.0f);
    return;
  }
  baseColor = textureSample(u_SceneColor, u_LinearSampler, v_UV).xyz;
  normal = normalize(normalRoughness.xyz);
  roughness_1 = clamp(normalRoughness.w, 0.03999999910593032837f, 1.0f);
  metallic = clamp(positionMetallic.w, 0.0f, 1.0f);
  viewDirection_1 = normalize(positionMetallic.xyz);
  reflectionDirection = normalize(reflect(viewDirection_1, normal));
  param_8 = reflectionDirection;
  let x_726 = sampleSky_vf3_(&(param_8));
  environment = x_726;
  reflectedColor = environment;
  visibility = 0.0f;
  if ((x_143.u_Reflection.x > 0.5f)) {
    param_9 = (positionMetallic.xyz + (normal * x_143.u_Reflection.w));
    param_10 = reflectionDirection;
    let x_747 = traceReflection_vf3_vf3_vf2_(&(param_9), &(param_10), &(param_11));
    hitUV_1 = param_11;
    if (x_747) {
      param_12 = hitUV_1;
      param_13 = roughness_1;
      let x_755 = blurredScene_vf2_f1_(&(param_12), &(param_13));
      reflectedColor = x_755;
      param_14 = hitUV_1;
      let x_758 = edgeVisibility_vf2_(&(param_14));
      visibility = x_758;
    }
  }
  fresnel = pow((1.0f - clamp(dot(-(viewDirection_1), normal), 0.0f, 1.0f)), 5.0f);
  reflectivity = (mix(0.03999999910593032837f, 1.0f, metallic) * mix(1.0f, fresnel, 0.34999999403953552246f));
  reflectivity = (reflectivity * ((1.0f - (roughness_1 * 0.69999998807907104492f)) * x_143.u_ReflectionQuality.y));
  param_15 = normal;
  let x_787 = sampleSky_vf3_(&(param_15));
  ambient = (x_787 * (0.03500000014901161194f + (0.03500000014901161194f * (1.0f - roughness_1))));
  reflectionResult = mix(environment, reflectedColor, vec3f(visibility));
  param_16 = ((baseColor + ambient) + (reflectionResult * reflectivity));
  let x_808 = presentColor_vf3_(&(param_16));
  o_Color = vec4f(x_808.x, x_808.y, x_808.z, 1.0f);
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn ssr_fragment(@location(0) v_UV_param : vec2f) -> main_out {
  v_UV = v_UV_param;
  main_1();
  return main_out(o_Color);
}

