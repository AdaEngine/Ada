// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOut {
  Color : vec4f,
  ViewPosition : vec3f,
  ViewNormal : vec3f,
  ViewTangent : vec4f,
  TextureCoordinate : vec2f,
  TextureFlags : vec4f,
  ShadowFlags : vec4f,
  ShadowPosition : vec4f,
  Roughness : f32,
  Metallic : f32,
  EmissiveStrength : f32,
  EmissiveLightThreshold : f32,
}

struct DirectionalLight3DUniform {
  /* @offset(0) */
  u_LightDirectionIntensity : vec4f,
  /* @offset(16) */
  u_LightRadianceAmbient : vec4f,
  /* @offset(32) */
  u_ShadowViewProjection : mat4x4f,
  /* @offset(96) */
  u_ShadowParameters : vec4f,
}

var<private> Input : VertexOut;

@group(0) @binding(6) var u_NormalTexture : texture_2d<f32>;

@group(0) @binding(9) var u_NormalSampler : sampler;

@group(0) @binding(1) var<uniform> x_354 : DirectionalLight3DUniform;

@group(0) @binding(10) var u_DirectionalShadowTexture : texture_2d<f32>;

@group(0) @binding(11) var u_DirectionalShadowSampler : sampler;

@group(0) @binding(4) var u_BaseColorTexture : texture_2d<f32>;

@group(0) @binding(7) var u_BaseColorSampler : sampler;

@group(0) @binding(5) var u_MetallicRoughnessTexture : texture_2d<f32>;

@group(0) @binding(8) var u_MetallicRoughnessSampler : sampler;

var<private> gl_FragDepth : f32;

var<private> gl_FragCoord : vec4f;

var<private> color : vec4f;

var<private> normalRoughness : vec4f;

var<private> viewPositionMetallic : vec4f;

@group(0) @binding(12) var u_EmissiveTexture : texture_2d<f32>;

@group(0) @binding(13) var u_EmissiveSampler : sampler;

fn srgbToLinear_vf3_(value : ptr<function, vec3f>) -> vec3f {
  let x_54 = *(value);
  let x_58 = *(value);
  let x_70 = *(value);
  return mix((x_54 / vec3f(12.9200000762939453125f)), pow(((x_58 + vec3f(0.05499999970197677612f)) / vec3f(1.05499994754791259766f)), vec3f(2.40000009536743164062f)), step(vec3f(0.04044999927282333374f), x_70));
}

fn cotangentFrame_vf3_vf3_vf2_(normal_2 : ptr<function, vec3f>, position_1 : ptr<function, vec3f>, uv : ptr<function, vec2f>) -> mat3x3f {
  var positionX : vec3f;
  var positionY : vec3f;
  var uvX : vec2f;
  var uvY : vec2f;
  var positionYPerpendicular : vec3f;
  var positionXPerpendicular : vec3f;
  var tangent : vec3f;
  var bitangent : vec3f;
  var scale : f32;
  positionX = dpdx(*(position_1));
  positionY = dpdy(*(position_1));
  uvX = dpdx(*(uv));
  uvY = dpdy(*(uv));
  positionYPerpendicular = cross(positionY, *(normal_2));
  positionXPerpendicular = cross(*(normal_2), positionX);
  tangent = ((positionYPerpendicular * uvX.x) + (positionXPerpendicular * uvY.x));
  bitangent = ((positionYPerpendicular * uvX.y) + (positionXPerpendicular * uvY.y));
  scale = inverseSqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 0.00000099999999747524f));
  let x_216 = (tangent * scale);
  let x_219 = (bitangent * scale);
  let x_220 = *(normal_2);
  return mat3x3f(vec3f(x_216.x, x_216.y, x_216.z), vec3f(x_219.x, x_219.y, x_219.z), vec3f(x_220.x, x_220.y, x_220.z));
}

fn materialNormal_() -> vec3f {
  var normal_4 : vec3f;
  var tangentNormal : vec3f;
  var tangent_1 : vec3f;
  var bitangent_1 : vec3f;
  var param_4 : vec3f;
  var param_5 : vec3f;
  var param_6 : vec2f;
  normal_4 = normalize(Input.ViewNormal);
  if ((Input.TextureFlags.z < 0.5f)) {
    let x_257 = normal_4;
    return x_257;
  }
  tangentNormal = ((textureSample(u_NormalTexture, u_NormalSampler, Input.TextureCoordinate).xyz * 2.0f) - vec3f(1.0f));
  if ((Input.TextureFlags.w > 0.5f)) {
    tangent_1 = normalize((Input.ViewTangent.xyz - (normal_4 * dot(normal_4, Input.ViewTangent.xyz))));
    bitangent_1 = (normalize(cross(normal_4, tangent_1)) * Input.ViewTangent.w);
    let x_309 = tangent_1;
    let x_310 = bitangent_1;
    let x_311 = normal_4;
    let x_325 = tangentNormal;
    return normalize((mat3x3f(vec3f(x_309.x, x_309.y, x_309.z), vec3f(x_310.x, x_310.y, x_310.z), vec3f(x_311.x, x_311.y, x_311.z)) * x_325));
  }
  param_4 = normal_4;
  param_5 = Input.ViewPosition;
  param_6 = Input.TextureCoordinate;
  let x_338 = cotangentFrame_vf3_vf3_vf2_(&(param_4), &(param_5), &(param_6));
  let x_339 = tangentNormal;
  return normalize((x_338 * x_339));
}

const x_149 = vec3f(1.0f);

fn fresnelSchlick_f1_vf3_(cosine : ptr<function, f32>, reflectanceAtNormal : ptr<function, vec3f>) -> vec3f {
  let x_148 = *(reflectanceAtNormal);
  let x_150 = *(reflectanceAtNormal);
  let x_152 = *(cosine);
  return (x_148 + ((x_149 - x_150) * pow(clamp((1.0f - x_152), 0.0f, 1.0f), 5.0f)));
}

fn distributionGGX_vf3_vf3_f1_(normal : ptr<function, vec3f>, halfway : ptr<function, vec3f>, roughness : ptr<function, f32>) -> f32 {
  var alpha : f32;
  var alphaSquared : f32;
  var normalHalfway : f32;
  var denominator : f32;
  alpha = (*(roughness) * *(roughness));
  alphaSquared = (alpha * alpha);
  normalHalfway = max(dot(*(normal), *(halfway)), 0.0f);
  denominator = (((normalHalfway * normalHalfway) * (alphaSquared - 1.0f)) + 1.0f);
  let x_98 = alphaSquared;
  let x_100 = denominator;
  let x_102 = denominator;
  return (x_98 / max(((3.14159274101257324219f * x_100) * x_102), 0.00000099999999747524f));
}

fn geometrySchlickGGX_f1_f1_(normalDirection : ptr<function, f32>, roughness_1 : ptr<function, f32>) -> f32 {
  var radius : f32;
  var k : f32;
  radius = (*(roughness_1) + 1.0f);
  k = ((radius * radius) / 8.0f);
  let x_118 = *(normalDirection);
  let x_119 = *(normalDirection);
  let x_120 = k;
  let x_123 = k;
  return (x_118 / max(((x_119 * (1.0f - x_120)) + x_123), 0.00000099999999747524f));
}

fn geometrySmith_vf3_vf3_vf3_f1_(normal_1 : ptr<function, vec3f>, viewDirection : ptr<function, vec3f>, lightDirection : ptr<function, vec3f>, roughness_2 : ptr<function, f32>) -> f32 {
  var param : f32;
  var param_1 : f32;
  var param_2 : f32;
  var param_3 : f32;
  param = max(dot(*(normal_1), *(viewDirection)), 0.0f);
  param_1 = *(roughness_2);
  let x_136 = geometrySchlickGGX_f1_f1_(&(param), &(param_1));
  param_2 = max(dot(*(normal_1), *(lightDirection)), 0.0f);
  param_3 = *(roughness_2);
  let x_144 = geometrySchlickGGX_f1_f1_(&(param_2), &(param_3));
  return (x_136 * x_144);
}

fn directionalShadow_vf3_vf3_(normal_3 : ptr<function, vec3f>, lightDirection_1 : ptr<function, vec3f>) -> f32 {
  var projected : vec3f;
  var uv_1 : vec2f;
  var normalLight : f32;
  var bias : f32;
  var visibility : f32;
  var y : i32;
  var x : i32;
  var offset_1 : vec2f;
  var storedDepth : f32;
  var x_358 : bool;
  var x_359 : bool;
  var x_366 : bool;
  var x_367 : bool;
  var x_395 : bool;
  var x_396 : bool;
  var x_404 : bool;
  var x_405 : bool;
  var x_412 : bool;
  var x_413 : bool;
  let x_347 = (Input.ShadowFlags.x < 0.5f);
  x_359 = x_347;
  if (!(x_347)) {
    x_358 = (x_354.u_ShadowParameters.x < 0.5f);
    x_359 = x_358;
  }
  x_367 = x_359;
  if (!(x_359)) {
    x_366 = (Input.ShadowPosition.w <= 0.0f);
    x_367 = x_366;
  }
  if (x_367) {
    return 1.0f;
  }
  projected = (Input.ShadowPosition.xyz / vec3f(Input.ShadowPosition.w));
  uv_1 = ((projected.xy * vec2f(0.5f, -0.5f)) + vec2f(0.5f));
  let x_389 = (projected.z < 0.0f);
  x_396 = x_389;
  if (!(x_389)) {
    x_395 = (projected.z > 1.0f);
    x_396 = x_395;
  }
  x_405 = x_396;
  if (!(x_396)) {
    x_404 = any((uv_1 < vec2f()));
    x_405 = x_404;
  }
  x_413 = x_405;
  if (!(x_405)) {
    x_412 = any((uv_1 > vec2f(1.0f)));
    x_413 = x_412;
  }
  if (x_413) {
    return 1.0f;
  }
  normalLight = max(dot(*(normal_3), *(lightDirection_1)), 0.0f);
  bias = (x_354.u_ShadowParameters.y + (x_354.u_ShadowParameters.z * (1.0f - normalLight)));
  visibility = 0.0f;
  y = -1i;
  loop {
    if ((y <= 1i)) {
    } else {
      break;
    }
    x = -1i;
    loop {
      if ((x <= 1i)) {
      } else {
        break;
      }
      offset_1 = (vec2f(f32(x), f32(y)) * x_354.u_ShadowParameters.w);
      storedDepth = textureSample(u_DirectionalShadowTexture, u_DirectionalShadowSampler, (uv_1 + offset_1)).x;
      visibility = (visibility + select(0.0f, 1.0f, ((projected.z - bias) <= storedDepth)));

      continuing {
        x = (x + 1i);
      }
    }

    continuing {
      y = (y + 1i);
    }
  }
  let x_483 = visibility;
  return (x_483 / 9.0f);
}

fn main_1() {
  var baseColor : vec4f;
  var sampledBaseColor : vec4f;
  var param_7 : vec3f;
  var roughness_3 : f32;
  var metallic : f32;
  var metallicRoughness : vec4f;
  var normal_5 : vec3f;
  var viewDirection_1 : vec3f;
  var lightDirection_2 : vec3f;
  var dayFacing : f32;
  var fresnelPower : f32;
  var fresnel : f32;
  var alpha_1 : f32;
  var atmosphereColor : vec3f;
  var halfway_1 : vec3f;
  var normalLight_1 : f32;
  var normalView : f32;
  var reflectanceAtNormal_1 : vec3f;
  var fresnel_1 : vec3f;
  var param_8 : f32;
  var param_9 : vec3f;
  var distribution : f32;
  var param_10 : vec3f;
  var param_11 : vec3f;
  var param_12 : f32;
  var geometry : f32;
  var param_13 : vec3f;
  var param_14 : vec3f;
  var param_15 : vec3f;
  var param_16 : f32;
  var specular : vec3f;
  var diffuseWeight : vec3f;
  var radiance : vec3f;
  var shadowVisibility : f32;
  var param_17 : vec3f;
  var param_18 : vec3f;
  var directLighting : vec3f;
  var ambient : vec3f;
  var emissiveVisibility : f32;
  var emissive : vec3f;
  var param_19 : vec3f;
  baseColor = Input.Color;
  if ((Input.TextureFlags.x > 0.5f)) {
    sampledBaseColor = textureSample(u_BaseColorTexture, u_BaseColorSampler, Input.TextureCoordinate);
    param_7 = sampledBaseColor.xyz;
    let x_510 = srgbToLinear_vf3_(&(param_7));
    baseColor = (baseColor * vec4f(x_510.x, x_510.y, x_510.z, sampledBaseColor.w));
  }
  roughness_3 = Input.Roughness;
  metallic = Input.Metallic;
  if ((Input.TextureFlags.y > 0.5f)) {
    metallicRoughness = textureSample(u_MetallicRoughnessTexture, u_MetallicRoughnessSampler, Input.TextureCoordinate);
    roughness_3 = clamp((roughness_3 * metallicRoughness.y), 0.03999999910593032837f, 1.0f);
    metallic = clamp((metallic * metallicRoughness.z), 0.0f, 1.0f);
  }
  let x_553 = materialNormal_();
  normal_5 = x_553;
  viewDirection_1 = normalize(-(Input.ViewPosition));
  lightDirection_2 = normalize(x_354.u_LightDirectionIntensity.xyz);
  gl_FragDepth = gl_FragCoord.z;
  if ((Input.ShadowFlags.y > 0.0f)) {
    gl_FragDepth = 1.0f;
    dayFacing = smoothstep(-0.30000001192092895508f, 0.55000001192092895508f, dot(normal_5, lightDirection_2));
    fresnelPower = mix((Input.ShadowFlags.y + 1.5f), (Input.ShadowFlags.y * 0.57999998331069946289f), dayFacing);
    fresnel = pow(clamp((1.0f - abs(dot(normal_5, viewDirection_1))), 0.0f, 1.0f), max(fresnelPower, 0.5f));
    alpha_1 = clamp((((baseColor.w * Input.ShadowFlags.z) * fresnel) * mix(0.28000000119209289551f, 1.0f, dayFacing)), 0.0f, 0.87999999523162841797f);
    atmosphereColor = (baseColor.xyz * mix(0.72000002861022949219f, 1.20000004768371582031f, dayFacing));
    color = vec4f(atmosphereColor.x, atmosphereColor.y, atmosphereColor.z, alpha_1);
    normalRoughness = vec4f(normal_5.x, normal_5.y, normal_5.z, 1.0f);
    let x_641 = Input.ViewPosition;
    viewPositionMetallic = vec4f(x_641.x, x_641.y, x_641.z, 0.0f);
    return;
  }
  halfway_1 = normalize((viewDirection_1 + lightDirection_2));
  normalLight_1 = max(dot(normal_5, lightDirection_2), 0.0f);
  normalView = max(dot(normal_5, viewDirection_1), 0.0f);
  reflectanceAtNormal_1 = mix(vec3f(0.03999999910593032837f), baseColor.xyz, vec3f(metallic));
  param_8 = max(dot(halfway_1, viewDirection_1), 0.0f);
  param_9 = reflectanceAtNormal_1;
  let x_677 = fresnelSchlick_f1_vf3_(&(param_8), &(param_9));
  fresnel_1 = x_677;
  param_10 = normal_5;
  param_11 = halfway_1;
  param_12 = roughness_3;
  let x_685 = distributionGGX_vf3_vf3_f1_(&(param_10), &(param_11), &(param_12));
  distribution = x_685;
  param_13 = normal_5;
  param_14 = viewDirection_1;
  param_15 = lightDirection_2;
  param_16 = roughness_3;
  let x_695 = geometrySmith_vf3_vf3_vf3_f1_(&(param_13), &(param_14), &(param_15), &(param_16));
  geometry = x_695;
  specular = ((fresnel_1 * (distribution * geometry)) / vec3f(max(((4.0f * normalView) * normalLight_1), 0.00009999999747378752f)));
  diffuseWeight = ((x_149 - fresnel_1) * (1.0f - metallic));
  radiance = (max(x_354.u_LightRadianceAmbient.xyz, vec3f()) * max(x_354.u_LightDirectionIntensity.w, 0.0f));
  param_17 = normal_5;
  param_18 = lightDirection_2;
  let x_732 = directionalShadow_vf3_vf3_(&(param_17), &(param_18));
  shadowVisibility = x_732;
  directLighting = ((((((diffuseWeight * baseColor.xyz) / vec3f(3.14159274101257324219f)) + specular) * radiance) * normalLight_1) * shadowVisibility);
  ambient = ((baseColor.xyz * (1.0f - metallic)) * max(x_354.u_LightRadianceAmbient.w, 0.0f));
  emissiveVisibility = 1.0f;
  if ((Input.EmissiveLightThreshold >= 0.0f)) {
    emissiveVisibility = (1.0f - smoothstep(Input.EmissiveLightThreshold, (Input.EmissiveLightThreshold + 0.15999999642372131348f), normalLight_1));
  }
  param_19 = textureSample(u_EmissiveTexture, u_EmissiveSampler, Input.TextureCoordinate).xyz;
  let x_785 = srgbToLinear_vf3_(&(param_19));
  emissive = ((x_785 * Input.EmissiveStrength) * emissiveVisibility);
  let x_796 = ((directLighting + ambient) + emissive);
  color = vec4f(x_796.x, x_796.y, x_796.z, 1.0f);
  normalRoughness = vec4f(normal_5.x, normal_5.y, normal_5.z, roughness_3);
  let x_808 = Input.ViewPosition;
  viewPositionMetallic = vec4f(x_808.x, x_808.y, x_808.z, metallic);
  return;
}

struct main_out {
  @builtin(frag_depth)
  gl_FragDepth_1 : f32,
  @location(0)
  color_1 : vec4f,
  @location(1)
  normalRoughness_1 : vec4f,
  @location(2)
  viewPositionMetallic_1 : vec4f,
}

@fragment
fn flat3d_fragment(@location(0) Input_param : vec4f, @location(1) Input_param_1 : vec3f, @location(2) Input_param_2 : vec3f, @location(3) Input_param_3 : vec4f, @location(4) Input_param_4 : vec2f, @location(5) Input_param_5 : vec4f, @location(6) Input_param_6 : vec4f, @location(7) Input_param_7 : vec4f, @location(8) Input_param_8 : f32, @location(9) Input_param_9 : f32, @location(10) Input_param_10 : f32, @location(11) Input_param_11 : f32, @builtin(position) gl_FragCoord_param : vec4f) -> main_out {
  Input.Color = Input_param;
  Input.ViewPosition = Input_param_1;
  Input.ViewNormal = Input_param_2;
  Input.ViewTangent = Input_param_3;
  Input.TextureCoordinate = Input_param_4;
  Input.TextureFlags = Input_param_5;
  Input.ShadowFlags = Input_param_6;
  Input.ShadowPosition = Input_param_7;
  Input.Roughness = Input_param_8;
  Input.Metallic = Input_param_9;
  Input.EmissiveStrength = Input_param_10;
  Input.EmissiveLightThreshold = Input_param_11;
  gl_FragCoord = gl_FragCoord_param;
  main_1();
  return main_out(gl_FragDepth, color, normalRoughness, viewPositionMetallic);
}

