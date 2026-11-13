import ada_engine::view::projectPosition;

// WESL port of glass.glsl. Attribute and varying locations are unchanged.

struct GlassVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) texCoordinate: vec2f,
    @location(2) params0: vec4f,
    @location(3) params1: vec4f,
    @location(4) params2: vec4f,
    @location(5) params3: vec4f,
    @location(6) info0: vec4f,
    @location(7) info1: vec4f,
}

@group(0) @binding(0) var u_BackgroundTexture: texture_2d<f32>;
@group(0) @binding(1) var u_BackgroundSampler: sampler;

@vertex
fn glass_vertex(
    @location(0) position: vec4f,
    @location(1) color: vec4f,
    @location(2) texCoordinate: vec2f,
    @location(3) params0: vec4f,   // x=blurRadius, y=cornerRadius, z=tintStrength, w=edgeShadow
    @location(4) params1: vec4f,   // x=cornerRoundnessExponent, y=glassThickness, z=refractiveIndex, w=dispersionStrength
    @location(5) params2: vec4f,   // x=fresnelDistanceRange, y=fresnelIntensity, z=fresnelEdgeSharpness, w=glareDistanceRange
    @location(6) params3: vec4f,   // x=glareAngleConvergence, y=glareOppositeSideBias, z=glareIntensity, w=glareEdgeSharpness
    @location(7) info0: vec4f,     // x=halfWidth, y=halfHeight, z=scaleFactor, w=opacity
    @location(8) info1: vec4f      // x=glareDirectionOffset, yzw reserved
) -> GlassVertex {
    return GlassVertex(projectPosition(position), color, texCoordinate, params0, params1, params2, params3, info0, info1);
}

// A 9x9 bilinear kernel keeps the same blur footprint with 81 taps.
const kBlurGridRadius: i32 = 4;

fn sdRoundedBox(p: vec2f, b: vec2f, r: f32) -> f32 {
    let q = abs(p) - b + vec2f(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0))) - r;
}

// GLSL smoothstep tolerates reversed edges (it evaluates the same polynomial); WGSL leaves them unspecified.
fn smoothstepAnyEdges(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn sampleBg(uv: vec2f) -> vec4f {
    // Captures have one mip. Explicit LOD also keeps optical branches valid
    // under WebGPU derivative-uniformity validation.
    return textureSampleLevel(u_BackgroundTexture, u_BackgroundSampler, uv, 0.0);
}

fn sampleBlurredChannel(uv: vec2f, texelSize: vec2f, radius: f32, channel: i32) -> f32 {
    if radius < 0.5 {
        return sampleBg(uv)[channel];
    }
    var value = 0.0;
    var totalWeight = 0.0;
    let sigma = max(radius * 0.42, 1.0);
    let stepPx = max(radius / f32(kBlurGridRadius), 1.0);

    for (var y = -kBlurGridRadius; y <= kBlurGridRadius; y++) {
        for (var x = -kBlurGridRadius; x <= kBlurGridRadius; x++) {
            let offsetPx = vec2f(f32(x), f32(y)) * stepPx;
            let w = exp(-dot(offsetPx, offsetPx) / (2.0 * sigma * sigma));
            let offset = offsetPx * texelSize;
            let sampleUV = clamp(uv + offset, vec2f(0.001), vec2f(0.999));
            value += sampleBg(sampleUV)[channel] * w;
            totalWeight += w;
        }
    }
    return value / totalWeight;
}

fn sampleBlurredAll(uv: vec2f, texelSize: vec2f, radius: f32) -> vec3f {
    if radius < 0.5 {
        return sampleBg(uv).rgb;
    }
    var value = vec3f(0.0);
    var totalWeight = 0.0;
    let sigma = max(radius * 0.42, 1.0);
    let stepPx = max(radius / f32(kBlurGridRadius), 1.0);

    for (var y = -kBlurGridRadius; y <= kBlurGridRadius; y++) {
        for (var x = -kBlurGridRadius; x <= kBlurGridRadius; x++) {
            let offsetPx = vec2f(f32(x), f32(y)) * stepPx;
            let w = exp(-dot(offsetPx, offsetPx) / (2.0 * sigma * sigma));
            let offset = offsetPx * texelSize;
            let sampleUV = clamp(uv + offset, vec2f(0.001), vec2f(0.999));
            value += sampleBg(sampleUV).rgb * w;
            totalWeight += w;
        }
    }
    return value / totalWeight;
}

@fragment
fn glass_fragment(input: GlassVertex) -> @location(0) vec4f {
    let blurRadius = input.params0.x;
    let cornerRadius = input.params0.y;
    let glassTintStr = saturate(input.params0.z);
    let edgeShadowStr = saturate(input.params0.w);

    let glassThickness = max(0.0, input.params1.y);
    let refractiveIndex = max(1.0, input.params1.z);
    let dispersionStrength = saturate(input.params1.w);

    let halfW = input.info0.x;
    let halfH = input.info0.y;
    let scaleFactor = max(input.info0.z, 1.0);
    let glassOpacity = saturate(input.info0.w);

    let bgTexSize = vec2f(textureDimensions(u_BackgroundTexture, 0));
    let texelSize = vec2f(1.0) / bgTexSize;

    // Local position from center (logical pixels).
    let localPos = (input.texCoordinate - vec2f(0.5)) * 2.0 * vec2f(halfW, halfH);
    let halfSize = vec2f(halfW, halfH);

    // --- SDF (simple rounded box, like OpenGlass) ---
    let sdf = sdRoundedBox(localPos, halfSize, cornerRadius);
    let edgeAA = max(length(vec2f(dpdx(sdf), dpdy(sdf))), 0.5);
    if sdf > edgeAA {
        discard;
    }

    let distFromEdge = -sdf;
    let effectiveSize = min(halfW * 2.0, halfH * 2.0);

    // --- Edge-band refraction (OpenGlass approach) ---
    let edgeBandMul = 0.1;
    let edgeBand = effectiveSize * edgeBandMul;
    var edgeFactor = 1.0 - smoothstep(0.0, edgeBand, distFromEdge);
    edgeFactor = edgeFactor * edgeFactor * edgeFactor * 2.0;

    // Refraction direction from SDF gradient (smooth, no cross-hair artifact).
    let kGradEps = 1.0;
    let sdfXp = sdRoundedBox(localPos + vec2f(kGradEps, 0.0), halfSize, cornerRadius);
    let sdfXm = sdRoundedBox(localPos - vec2f(kGradEps, 0.0), halfSize, cornerRadius);
    let sdfYp = sdRoundedBox(localPos + vec2f(0.0, kGradEps), halfSize, cornerRadius);
    let sdfYm = sdRoundedBox(localPos - vec2f(0.0, kGradEps), halfSize, cornerRadius);
    let sdfGrad = vec2f(sdfXp - sdfXm, sdfYp - sdfYm);
    let gradLen = length(sdfGrad);
    let toCenter = select(vec2f(0.0), -sdfGrad / gradLen, gradLen > 1e-4);

    // Zoom / magnification from glass thickness.
    let zoom = 1.0 + glassThickness * 0.0015;
    let normFromCenter = localPos / max(halfSize, vec2f(1e-4));
    let distNorm = length(normFromCenter);
    let zoomFactor = max(0.0, 1.0 - distNorm * distNorm);
    let zoomStrength = zoom - 1.0;
    let minSide = min(halfW, halfH);
    let magOffset = -normFromCenter * zoomFactor * zoomStrength * minSide;

    // Refraction and chromatic aberration strengths.
    let refrStr = (refractiveIndex - 1.0) * 5.0;
    let disp = edgeFactor * refrStr * edgeBand;
    let chrome = edgeFactor * dispersionStrength * 4.0;

    let greenOff = toCenter * disp + magOffset;

    // --- Sample background ---
    let blurPhysical = max(blurRadius * scaleFactor, 0.0);
    let fragPx = input.position.xy;

    let redOff = toCenter * (disp + chrome) + magOffset;
    let blueOff = toCenter * (disp - chrome) + magOffset;

    let redUV = clamp((fragPx + redOff * scaleFactor) / bgTexSize, vec2f(0.001), vec2f(0.999));
    let greenUV = clamp((fragPx + greenOff * scaleFactor) / bgTexSize, vec2f(0.001), vec2f(0.999));
    let blueUV = clamp((fragPx + blueOff * scaleFactor) / bgTexSize, vec2f(0.001), vec2f(0.999));

    var color: vec3f;
    // Regular/clear glass has no dispersion: all channels share one blur.
    if chrome == 0.0 {
        color = sampleBlurredAll(greenUV, texelSize, blurPhysical);
    } else {
        color = vec3f(
            sampleBlurredChannel(redUV, texelSize, blurPhysical, 0),
            sampleBlurredChannel(greenUV, texelSize, blurPhysical, 1),
            sampleBlurredChannel(blueUV, texelSize, blurPhysical, 2)
        );
    }

    // --- Luminance-adaptive tinting (OpenGlass light-mode path) ---
    let lum = dot(color, vec3f(0.299, 0.587, 0.114));
    let tintAmount = max(lum, 0.08) * glassTintStr * mix(1.0, 0.35, lum);
    color = vec3f(1.0) - (vec3f(1.0) - color) * (1.0 - tintAmount);

    // --- Shadow ---
    let shadowScale = saturate(1.0 - lum * 0.8);
    let overallShadow = 0.02 * shadowScale;
    let edgeShadow = (1.0 - smoothstep(0.0, 20.0, distFromEdge)) * edgeShadowStr * shadowScale;
    color = color * (1.0 - overallShadow - edgeShadow);

    // --- Anti-aliased alpha ---
    let aa = saturate(0.5 - sdf / (edgeAA * 2.0));

    // --- Thin directional border (OpenGlass style, softened) ---
    let borderWidth = 1.5;
    let borderInner = smoothstepAnyEdges(borderWidth, 0.2, distFromEdge);
    let borderOuter = saturate(distFromEdge / (edgeAA * 0.8));
    let borderMask = borderInner * borderOuter * aa;

    let borderNorm = select(vec2f(0.0), sdfGrad / gradLen, gradLen > 1e-4);
    let lightDir = normalize(vec2f(1.0, 1.0));
    var dirFactor = abs(dot(borderNorm, lightDir));
    dirFactor = dirFactor * dirFactor;
    let borderLight = mix(0.35, 0.70, dirFactor) * mix(0.5, 1.0, lum);
    color = mix(color, vec3f(1.0), borderMask * borderLight * 0.6);

    // Optional tint color overlay from vertex data.
    color = mix(color, input.color.rgb, input.color.a * 0.3);

    return vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), aa * glassOpacity);
}
