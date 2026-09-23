// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

@group(0) @binding(0) var u_BackgroundTexture : texture_2d<f32>;

@group(0) @binding(1) var u_BackgroundSampler : sampler;

var<private> v_GlassParams0 : vec4f;

var<private> v_GlassParams1 : vec4f;

var<private> v_GlassInfo0 : vec4f;

var<private> v_TexCoordinate : vec2f;

var<private> gl_FragCoord : vec4f;

var<private> v_Color : vec4f;

var<private> o_Color : vec4f;

var<private> v_GlassParams2 : vec4f;

var<private> v_GlassParams3 : vec4f;

var<private> v_GlassInfo1 : vec4f;

fn saturate_f1_(v : ptr<function, f32>) -> f32 {
  let x_34 = *(v);
  return clamp(x_34, 0.0f, 1.0f);
}

fn sdRoundedBox_vf2_vf2_f1_(p : ptr<function, vec2f>, b : ptr<function, vec2f>, r : ptr<function, f32>) -> f32 {
  var q : vec2f;
  q = ((abs(*(p)) - *(b)) + vec2f(*(r)));
  let x_51 = q.x;
  let x_54 = q.y;
  let x_57 = q;
  let x_62 = *(r);
  return ((min(max(x_51, x_54), 0.0f) + length(max(x_57, vec2f()))) - x_62);
}

fn sampleBg_vf2_(uv : ptr<function, vec2f>) -> vec4f {
  let x_77 = textureSample(u_BackgroundTexture, u_BackgroundSampler, *(uv));
  return x_77;
}

const x_140 = vec2f(0.00100000004749745131f);

const x_142 = vec2f(0.99900001287460327148f);

fn sampleBlurredChannel_vf2_vf2_f1_i1_(uv_1 : ptr<function, vec2f>, texelSize : ptr<function, vec2f>, radius : ptr<function, f32>, channel : ptr<function, i32>) -> f32 {
  var value : f32;
  var totalWeight : f32;
  var sigma : f32;
  var stepPx : f32;
  var y : i32;
  var x : i32;
  var offsetPx : vec2f;
  var w : f32;
  var offset_1 : vec2f;
  var sUV : vec2f;
  var param : vec2f;
  value = 0.0f;
  totalWeight = 0.0f;
  sigma = max((*(radius) * 0.41999998688697814941f), 1.0f);
  stepPx = max((*(radius) / 10.0f), 1.0f);
  y = -10i;
  loop {
    if ((y <= 10i)) {
    } else {
      break;
    }
    x = -10i;
    loop {
      if ((x <= 10i)) {
      } else {
        break;
      }
      offsetPx = (vec2f(f32(x), f32(y)) * stepPx);
      w = exp((-(dot(offsetPx, offsetPx)) / ((2.0f * sigma) * sigma)));
      offset_1 = (offsetPx * *(texelSize));
      sUV = clamp((*(uv_1) + offset_1), x_140, x_142);
      param = sUV;
      let x_146 = sampleBg_vf2_(&(param));
      value = (value + (x_146[*(channel)] * w));
      totalWeight = (totalWeight + w);

      continuing {
        x = (x + 1i);
      }
    }

    continuing {
      y = (y + 1i);
    }
  }
  let x_161 = value;
  let x_162 = totalWeight;
  return (x_161 / x_162);
}

const x_293 = vec2f(1.0f, 0.0f);

const x_312 = vec2f(0.0f, 1.0f);

const x_610 = vec3f(1.0f);

fn main_1() {
  var blurRadius : f32;
  var cornerRadius : f32;
  var glassTintStr : f32;
  var param_1 : f32;
  var edgeShadowStr : f32;
  var param_2 : f32;
  var glassThickness : f32;
  var refractiveIndex : f32;
  var dispersionStrength : f32;
  var param_3 : f32;
  var halfW : f32;
  var halfH : f32;
  var scaleFactor : f32;
  var glassOpacity : f32;
  var param_4 : f32;
  var bgTexSizeI : vec2i;
  var bgTexSize : vec2f;
  var texelSize_1 : vec2f;
  var localPos : vec2f;
  var halfSize : vec2f;
  var sdf : f32;
  var param_5 : vec2f;
  var param_6 : vec2f;
  var param_7 : f32;
  var edgeAA : f32;
  var distFromEdge : f32;
  var effectiveSize : f32;
  var edgeBandMul : f32;
  var edgeBand : f32;
  var edgeFactor : f32;
  var sdfXp : f32;
  var param_8 : vec2f;
  var param_9 : vec2f;
  var param_10 : f32;
  var sdfXm : f32;
  var param_11 : vec2f;
  var param_12 : vec2f;
  var param_13 : f32;
  var sdfYp : f32;
  var param_14 : vec2f;
  var param_15 : vec2f;
  var param_16 : f32;
  var sdfYm : f32;
  var param_17 : vec2f;
  var param_18 : vec2f;
  var param_19 : f32;
  var sdfGrad : vec2f;
  var gradLen : f32;
  var toCenter : vec2f;
  var x_344 : vec2f;
  var zoom : f32;
  var normFromCenter : vec2f;
  var distNorm : f32;
  var zoomFactor : f32;
  var zoomStrength : f32;
  var minSide : f32;
  var magOffset : vec2f;
  var refrStr : f32;
  var disp : f32;
  var chrome : f32;
  var greenOff : vec2f;
  var blurPhysical : f32;
  var fragPx : vec2f;
  var redOff : vec2f;
  var blueOff : vec2f;
  var redUV : vec2f;
  var greenUV : vec2f;
  var blueUV : vec2f;
  var r_1 : f32;
  var param_20 : vec2f;
  var param_21 : vec2f;
  var param_22 : f32;
  var param_23 : i32;
  var g : f32;
  var param_24 : vec2f;
  var param_25 : vec2f;
  var param_26 : f32;
  var param_27 : i32;
  var b_1 : f32;
  var param_28 : vec2f;
  var param_29 : vec2f;
  var param_30 : f32;
  var param_31 : i32;
  var color : vec3f;
  var lum : f32;
  var tintAmount : f32;
  var shadowScale : f32;
  var param_32 : f32;
  var overallShadow : f32;
  var edgeShadow : f32;
  var aa : f32;
  var param_33 : f32;
  var borderWidth : f32;
  var borderInner : f32;
  var borderOuter : f32;
  var param_34 : f32;
  var borderMask : f32;
  var borderNorm : vec2f;
  var x_582 : vec2f;
  var lightDir : vec2f;
  var dirFactor : f32;
  var borderLight : f32;
  blurRadius = v_GlassParams0.x;
  cornerRadius = v_GlassParams0.y;
  param_1 = v_GlassParams0.z;
  let x_180 = saturate_f1_(&(param_1));
  glassTintStr = x_180;
  param_2 = v_GlassParams0.w;
  let x_186 = saturate_f1_(&(param_2));
  edgeShadowStr = x_186;
  glassThickness = max(0.0f, v_GlassParams1.y);
  refractiveIndex = max(1.0f, v_GlassParams1.z);
  param_3 = v_GlassParams1.w;
  let x_200 = saturate_f1_(&(param_3));
  dispersionStrength = x_200;
  halfW = v_GlassInfo0.x;
  halfH = v_GlassInfo0.y;
  scaleFactor = max(v_GlassInfo0.z, 1.0f);
  param_4 = v_GlassInfo0.w;
  let x_216 = saturate_f1_(&(param_4));
  glassOpacity = x_216;
  bgTexSizeI = vec2i(textureDimensions(u_BackgroundTexture, 0i));
  bgTexSize = vec2f(bgTexSizeI);
  texelSize_1 = (vec2f(1.0f) / bgTexSize);
  localPos = (((v_TexCoordinate - vec2f(0.5f)) * 2.0f) * vec2f(halfW, halfH));
  halfSize = vec2f(halfW, halfH);
  param_5 = localPos;
  param_6 = halfSize;
  param_7 = cornerRadius;
  let x_256 = sdRoundedBox_vf2_vf2_f1_(&(param_5), &(param_6), &(param_7));
  sdf = x_256;
  edgeAA = max(length(vec2f(dpdx(sdf), dpdy(sdf))), 0.5f);
  distFromEdge = -(sdf);
  effectiveSize = min((halfW * 2.0f), (halfH * 2.0f));
  edgeBandMul = 0.10000000149011611938f;
  edgeBand = (effectiveSize * edgeBandMul);
  edgeFactor = (1.0f - smoothstep(0.0f, edgeBand, distFromEdge));
  edgeFactor = (((edgeFactor * edgeFactor) * edgeFactor) * 2.0f);
  param_8 = (localPos + x_293);
  param_9 = halfSize;
  param_10 = cornerRadius;
  let x_300 = sdRoundedBox_vf2_vf2_f1_(&(param_8), &(param_9), &(param_10));
  sdfXp = x_300;
  param_11 = (localPos - x_293);
  param_12 = halfSize;
  param_13 = cornerRadius;
  let x_309 = sdRoundedBox_vf2_vf2_f1_(&(param_11), &(param_12), &(param_13));
  sdfXm = x_309;
  param_14 = (localPos + x_312);
  param_15 = halfSize;
  param_16 = cornerRadius;
  let x_319 = sdRoundedBox_vf2_vf2_f1_(&(param_14), &(param_15), &(param_16));
  sdfYp = x_319;
  param_17 = (localPos - x_312);
  param_18 = halfSize;
  param_19 = cornerRadius;
  let x_328 = sdRoundedBox_vf2_vf2_f1_(&(param_17), &(param_18), &(param_19));
  sdfYm = x_328;
  sdfGrad = vec2f((sdfXp - sdfXm), (sdfYp - sdfYm));
  gradLen = length(sdfGrad);
  if ((gradLen > 0.00009999999747378752f)) {
    x_344 = (-(sdfGrad) / vec2f(gradLen));
  } else {
    x_344 = vec2f();
  }
  toCenter = x_344;
  zoom = (1.0f + (glassThickness * 0.00150000001303851604f));
  normFromCenter = (localPos / max(halfSize, vec2f(0.00009999999747378752f)));
  distNorm = length(normFromCenter);
  zoomFactor = max(0.0f, (1.0f - (distNorm * distNorm)));
  zoomStrength = (zoom - 1.0f);
  minSide = min(halfW, halfH);
  magOffset = (((-(normFromCenter) * zoomFactor) * zoomStrength) * minSide);
  refrStr = ((refractiveIndex - 1.0f) * 5.0f);
  disp = ((edgeFactor * refrStr) * edgeBand);
  chrome = ((edgeFactor * dispersionStrength) * 4.0f);
  greenOff = ((toCenter * disp) + magOffset);
  blurPhysical = max((blurRadius * scaleFactor), 0.0f);
  fragPx = gl_FragCoord.xy;
  redOff = ((toCenter * (disp + chrome)) + magOffset);
  blueOff = ((toCenter * (disp - chrome)) + magOffset);
  redUV = clamp(((fragPx + (redOff * scaleFactor)) / bgTexSize), x_140, x_142);
  greenUV = clamp(((fragPx + (greenOff * scaleFactor)) / bgTexSize), x_140, x_142);
  blueUV = clamp(((fragPx + (blueOff * scaleFactor)) / bgTexSize), x_140, x_142);
  param_20 = redUV;
  param_21 = texelSize_1;
  param_22 = blurPhysical;
  param_23 = 0i;
  let x_473 = sampleBlurredChannel_vf2_vf2_f1_i1_(&(param_20), &(param_21), &(param_22), &(param_23));
  r_1 = x_473;
  param_24 = greenUV;
  param_25 = texelSize_1;
  param_26 = blurPhysical;
  param_27 = 1i;
  let x_482 = sampleBlurredChannel_vf2_vf2_f1_i1_(&(param_24), &(param_25), &(param_26), &(param_27));
  g = x_482;
  param_28 = blueUV;
  param_29 = texelSize_1;
  param_30 = blurPhysical;
  param_31 = 2i;
  let x_492 = sampleBlurredChannel_vf2_vf2_f1_i1_(&(param_28), &(param_29), &(param_30), &(param_31));
  b_1 = x_492;
  color = vec3f(r_1, g, b_1);
  lum = dot(color, vec3f(0.29899999499320983887f, 0.58700001239776611328f, 0.11400000005960464478f));
  tintAmount = ((max(lum, 0.07999999821186065674f) * glassTintStr) * mix(1.0f, 0.34999999403953552246f, lum));
  color = (vec3f(1.0f) - ((vec3f(1.0f) - color) * (1.0f - tintAmount)));
  param_32 = (1.0f - (lum * 0.80000001192092895508f));
  let x_531 = saturate_f1_(&(param_32));
  shadowScale = x_531;
  overallShadow = (0.01999999955296516418f * shadowScale);
  edgeShadow = (((1.0f - smoothstep(0.0f, 20.0f, distFromEdge)) * edgeShadowStr) * shadowScale);
  color = (color * ((1.0f - overallShadow) - edgeShadow));
  param_33 = (0.5f - (sdf / (edgeAA * 2.0f)));
  let x_558 = saturate_f1_(&(param_33));
  aa = x_558;
  borderWidth = 1.5f;
  borderInner = smoothstep(borderWidth, 0.20000000298023223877f, distFromEdge);
  param_34 = (distFromEdge / (edgeAA * 0.80000001192092895508f));
  let x_572 = saturate_f1_(&(param_34));
  borderOuter = x_572;
  borderMask = ((borderInner * borderOuter) * aa);
  if ((gradLen > 0.00009999999747378752f)) {
    x_582 = (sdfGrad / vec2f(gradLen));
  } else {
    x_582 = vec2f();
  }
  borderNorm = x_582;
  lightDir = vec2f(0.70710676908493041992f);
  dirFactor = abs(dot(borderNorm, lightDir));
  dirFactor = (dirFactor * dirFactor);
  borderLight = (mix(0.34999999403953552246f, 0.69999998807907104492f, dirFactor) * mix(0.5f, 1.0f, lum));
  color = mix(color, x_610, vec3f(((borderMask * borderLight) * 0.60000002384185791016f)));
  color = mix(color, v_Color.xyz, vec3f((v_Color.w * 0.30000001192092895508f)));
  let x_632 = clamp(color, vec3f(), x_610);
  o_Color = vec4f(x_632.x, x_632.y, x_632.z, (aa * glassOpacity));
  return;
}

struct main_out {
  @location(0)
  o_Color_1 : vec4f,
}

@fragment
fn glass_fragment(@location(2) v_GlassParams0_param : vec4f, @location(3) v_GlassParams1_param : vec4f, @location(6) v_GlassInfo0_param : vec4f, @location(1) v_TexCoordinate_param : vec2f, @builtin(position) gl_FragCoord_param : vec4f, @location(0) v_Color_param : vec4f, @location(4) v_GlassParams2_param : vec4f, @location(5) v_GlassParams3_param : vec4f, @location(7) v_GlassInfo1_param : vec4f) -> main_out {
  v_GlassParams0 = v_GlassParams0_param;
  v_GlassParams1 = v_GlassParams1_param;
  v_GlassInfo0 = v_GlassInfo0_param;
  v_TexCoordinate = v_TexCoordinate_param;
  gl_FragCoord = gl_FragCoord_param;
  v_Color = v_Color_param;
  v_GlassParams2 = v_GlassParams2_param;
  v_GlassParams3 = v_GlassParams3_param;
  v_GlassInfo1 = v_GlassInfo1_param;
  main_1();
  return main_out(o_Color);
}

