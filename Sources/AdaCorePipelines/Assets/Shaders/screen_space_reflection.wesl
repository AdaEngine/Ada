import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::environment_composite::{
    sceneColor, normalRoughness, viewPositionMetallic, linearSampler, gBufferSampler, environment,
    srgbToLinear, presentColor, applyFog,
};

@group(0) @binding(5) var environmentImage: texture_2d<f32>;
@group(0) @binding(6) var radianceImage: texture_2d<f32>;
@group(0) @binding(7) var radianceSampler: sampler;
@group(0) @binding(8) var indirectImage: texture_2d<f32>;
@group(0) @binding(9) var aoImage: texture_2d<f32>;
@group(0) @binding(10) var iblSampler: sampler;
@group(0) @binding(17) var reflectionResponse: texture_2d<f32>;
@group(0) @binding(18) var prefilteredEnvironment: texture_2d<f32>;
@group(0) @binding(20) var diffuseImage: texture_2d<f32>;

const PI: f32 = 3.14159265359;
const MINIMUM_TRACED_REFLECTIVITY: f32 = 0.004;

@vertex
fn ssr_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn sampleAt(image: texture_2d<f32>, imageSampler: sampler, uv: vec2f) -> vec4f {
    return textureSampleLevel(image, imageSampler, uv, 0.0);
}

fn sampleDiffuseGI(uv: vec2f, position: vec3f, normal: vec3f) -> vec3f {
    if environment.diffuseGI.x < 0.5 {
        return vec3f(0.0);
    }
    let size = vec2f(textureDimensions(diffuseImage, 0));
    let pixel = uv * size - 0.5;
    let base = floor(pixel);
    let fraction = fract(pixel);
    var sum = vec3f(0.0);
    var weights = 0.0;
    for (var y = 0; y <= 1; y++) {
        for (var x = 0; x <= 1; x++) {
            let at = clamp((base + vec2f(f32(x), f32(y)) + 0.5) / size, vec2f(0.0), vec2f(1.0));
            let otherPosition = sampleAt(viewPositionMetallic, gBufferSampler, at).xyz;
            let otherNormal = sampleAt(normalRoughness, gBufferSampler, at).xyz;
            if length(otherNormal) < 0.1 {
                continue;
            }
            let bilinear = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, y == 0);
            let weight = bilinear * pow(max(dot(normal, normalize(otherNormal)), 0.0), 16.0)
                * exp(-abs(position.z - otherPosition.z) / max(0.04, environment.diffuseGI.y * 4.0));
            sum += sampleAt(diffuseImage, gBufferSampler, at).rgb * weight;
            weights += weight;
        }
    }
    return sum / max(weights, 0.00001);
}

fn skyUV(direction: vec3f) -> vec2f {
    return vec2f(atan2(direction.z, direction.x) / (2.0 * PI) + 0.5, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
}

fn rotateSky(direction: vec3f, angle: f32) -> vec3f {
    let rotated = mat2x2f(cos(angle), -sin(angle), sin(angle), cos(angle)) * direction.xz;
    return vec3f(rotated.x, direction.y, rotated.y);
}

fn proceduralSky(direction: vec3f) -> vec3f {
    let height = clamp(direction.y, -1.0, 1.0);
    let hemisphere = select(environment.groundColor.rgb, environment.zenithColor.rgb, height >= 0.0);
    let sky = mix(environment.horizonColor.rgb, hemisphere, pow(abs(height), 0.55));
    if environment.environmentFlags.w < 0.5 {
        return sky;
    }
    let gridPosition = skyUV(direction) * vec2f(220.0, 110.0);
    var hashInput = fract(vec3f(floor(gridPosition), environment.starfield.w) * vec3f(0.1031, 0.1030, 0.0973));
    hashInput += dot(hashInput, hashInput.yzx + 33.33);
    let existence = fract((hashInput.x + hashInput.y) * hashInput.z);
    let offset = vec2f(fract(existence * 17.17 + hashInput.x), fract(existence * 31.73 + hashInput.y));
    let distanceToStar = length((fract(gridPosition) - offset) / max(environment.starfield.z, 0.1));
    let threshold = mix(0.998, 0.72, environment.starfield.x);
    let starExists = step(threshold, existence);
    let star = (1.0 - smoothstep(0.0, 0.11, distanceToStar)) * starExists;
    let glow = (1.0 - smoothstep(0.0, 0.42, distanceToStar)) * starExists * 0.22;
    let starColor = mix(vec3f(1.0, 0.72, 0.46), vec3f(0.58, 0.76, 1.0), fract(existence * 47.0));
    return sky + starColor * (star + glow) * environment.starfield.y;
}

// Preserve implicit LOD for authored sky textures, including calls from the reflective surface branch.
@diagnostic(off, derivative_uniformity)
fn sampleSky(viewDirection: vec3f) -> vec3f {
    if environment.environmentFlags.x < 0.5 {
        return srgbToLinear(environment.clearColor.rgb);
    }
    let direction = normalize((environment.inverseView * vec4f(viewDirection, 0.0)).xyz);
    if environment.ibl.x > 0.5 && environment.ibl.w > 0.5 {
        return textureSample(radianceImage, radianceSampler, skyUV(rotateSky(direction, environment.ibl.z))).rgb * environment.ibl.y;
    }
    if environment.environmentFlags.y > 0.5 {
        return srgbToLinear(textureSample(environmentImage, linearSampler, skyUV(direction)).rgb) * environment.environmentFlags.z;
    }
    return srgbToLinear(proceduralSky(direction)) * environment.environmentFlags.z;
}

fn edgeVisibility(uv: vec2f) -> f32 {
    let edge = min(uv, vec2f(1.0) - uv);
    return smoothstep(0.0, environment.reflectionQuality.z, min(edge.x, edge.y));
}

fn blurredScene(uv: vec2f, roughness: f32) -> vec3f {
    let radius = 0.012 * roughness * roughness;
    let horizontal = vec2f(radius, 0.0);
    let vertical = vec2f(0.0, radius);
    return sampleAt(sceneColor, linearSampler, uv).rgb * 0.4
        + sampleAt(sceneColor, linearSampler, uv + horizontal).rgb * 0.15
        + sampleAt(sceneColor, linearSampler, uv - horizontal).rgb * 0.15
        + sampleAt(sceneColor, linearSampler, uv + vertical).rgb * 0.15
        + sampleAt(sceneColor, linearSampler, uv - vertical).rgb * 0.15;
}

struct ScreenPoint {
    uv: vec2f,
    visible: bool,
}

fn projectToScreen(point: vec3f) -> ScreenPoint {
    let clip = environment.projection * vec4f(point, 1.0);
    if clip.w <= 0.0 {
        return ScreenPoint(vec2f(0.0), false);
    }
    let uv = clip.xy / clip.w * vec2f(0.5, -0.5) + 0.5;
    return ScreenPoint(uv, !(any(uv <= vec2f(0.0)) || any(uv >= vec2f(1.0))));
}

fn depthBehindSurface(point: vec3f, uv: vec2f) -> f32 {
    let scenePosition = sampleAt(viewPositionMetallic, gBufferSampler, uv).xyz;
    return select(-1000000.0, point.z - scenePosition.z, length(scenePosition) > 0.0001);
}

// Use double strides for the march and four refinements after crossing a surface.
fn traceReflection(origin: vec3f, direction: vec3f) -> ScreenPoint {
    let stride = environment.reflection.z * 2.0;
    let thickness = environment.reflection.w;
    var previous = origin + direction * thickness;
    var ray = previous;
    let steps = (min(i32(environment.reflectionQuality.x), 64) + 1) / 2;
    for (var stepIndex = 0; stepIndex < 32; stepIndex++) {
        if stepIndex >= steps {
            break;
        }
        ray += direction * stride;
        if distance(ray, origin) > environment.reflection.y {
            break;
        }
        let projected = projectToScreen(ray);
        if !projected.visible {
            break;
        }
        let behind = depthBehindSurface(ray, projected.uv);
        if behind > 0.0 && behind < stride + thickness {
            var nearPoint = previous;
            var farPoint = ray;
            for (var refinement = 0; refinement < 4; refinement++) {
                let middle = (nearPoint + farPoint) * 0.5;
                let projectedMiddle = projectToScreen(middle);
                if !projectedMiddle.visible {
                    break;
                }
                if depthBehindSurface(middle, projectedMiddle.uv) > 0.0 {
                    farPoint = middle;
                } else {
                    nearPoint = middle;
                }
            }
            let hit = projectToScreen(farPoint);
            if hit.visible && abs(depthBehindSurface(farPoint, hit.uv)) <= thickness {
                return hit;
            }
        }
        previous = ray;
    }
    return ScreenPoint(vec2f(0.0), false);
}

fn ambientOcclusion(uv: vec2f, position: vec3f, normal: vec3f) -> f32 {
    if environment.quality.x < 0.5 {
        return 1.0;
    }
    let size = vec2f(textureDimensions(aoImage, 0));
    let base = floor(uv * size - 0.5);
    let fraction = fract(uv * size - 0.5);
    var sum = 0.0;
    var weights = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let at = clamp((base + vec2f(f32(x), f32(y)) + 0.5) / size, 0.5 / size, vec2f(1.0) - 0.5 / size);
            let other = sampleAt(viewPositionMetallic, gBufferSampler, at).xyz;
            let otherNormal = sampleAt(normalRoughness, gBufferSampler, at).xyz;
            if other.z <= 0.0 || length(otherNormal) < 0.1 {
                continue;
            }
            let bilinear = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, y == 0);
            var weight = bilinear * exp(-abs(position.z - other.z) / max(0.02, environment.quality.y * 0.1));
            weight *= pow(max(dot(normal, normalize(otherNormal)), 0.0), 8.0);
            sum += sampleAt(aoImage, gBufferSampler, at).r * weight;
            weights += weight;
        }
    }
    if weights > 0.0001 {
        return sum / weights;
    }
    return 1.0;
}

@diagnostic(off, derivative_uniformity)
fn probeReflection(viewPosition: vec3f, viewDirection: vec3f, roughness: f32) -> vec3f {
    var direction = normalize((environment.inverseView * vec4f(viewDirection, 0.0)).xyz);
    let position = (environment.inverseView * vec4f(viewPosition, 1.0)).xyz;
    let minimum = environment.probeMinimum.xyz;
    let maximum = environment.probeMaximum.xyz;
    if environment.probePosition.w > 0.5 && all(position >= minimum) && all(position <= maximum) {
        let flatAxis = abs(direction) < vec3f(0.000001);
        let safeDirection = select(direction, vec3f(0.000001), flatAxis);
        let boundary = select(minimum, maximum, direction >= vec3f(0.0));
        let travel = select((boundary - position) / safeDirection, vec3f(1e20), flatAxis);
        let projected = position + direction * min(travel.x, min(travel.y, travel.z)) - environment.probePosition.xyz;
        if dot(projected, projected) > 0.000001 {
            direction = normalize(projected);
        }
    }
    let uv = skyUV(rotateSky(direction, environment.ibl.z));
    let levels = max(environment.reflectionQuality.w, 2.0);
    let layer = roughness * (levels - 1.0);
    let lower = floor(layer);
    let upper = min(lower + 1.0, levels - 1.0);
    let texels = f32(textureDimensions(prefilteredEnvironment, 0).y) / levels;
    let y = clamp(uv.y, 0.5 / texels, 1.0 - 0.5 / texels);
    let a = textureSample(prefilteredEnvironment, iblSampler, vec2f(uv.x, (lower + y) / levels)).rgb;
    let b = textureSample(prefilteredEnvironment, iblSampler, vec2f(uv.x, (upper + y) / levels)).rgb;
    return mix(a, b, layer - lower) * environment.ibl.y;
}

fn composite(color: vec3f, position: vec3f, skyAmount: f32, isSky: bool, input: FullscreenVertex) -> vec4f {
    let fogged = applyFog(color, position, skyAmount, isSky, input.uv);
    return vec4f(presentColor(fogged, input.uv, input.position.xy), 1.0);
}

@fragment
fn ssr_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv;
    let surface = sampleAt(normalRoughness, gBufferSampler, uv);
    let positionMetallic = sampleAt(viewPositionMetallic, gBufferSampler, uv);
    let position = positionMetallic.xyz;
    let foreground = sampleAt(sceneColor, linearSampler, uv);
    if length(surface.xyz) < 0.1 || length(position) < 0.0001 {
        let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
        let viewFar = environment.inverseProjection * vec4f(ndc, 1.0, 1.0);
        let viewRay = normalize(viewFar.xyz / viewFar.w);
        // The HDR scene holds premultiplied transparent geometry and particles at sky pixels.
        let skyWithForeground = foreground.rgb + sampleSky(viewRay) * (1.0 - clamp(foreground.a, 0.0, 1.0));
        return composite(skyWithForeground, viewRay * 1000.0, environment.fogRange.x, true, input);
    }

    let normal = normalize(surface.xyz);
    let ao = ambientOcclusion(uv, position, normal);
    let indirect = sampleAt(indirectImage, linearSampler, uv).rgb;
    var baseColor = max(foreground.rgb - indirect * (1.0 - ao), vec3f(0.0));
    baseColor += sampleDiffuseGI(uv, position, normal) * ao;
    let roughness = clamp(surface.w, 0.04, 1.0);
    let metallic = clamp(positionMetallic.w, 0.0, 1.0);
    let viewDirection = normalize(position);
    let reflectionDirection = normalize(reflect(viewDirection, normal));
    if environment.ibl.x > 0.5 {
        if environment.quality.w > 0.5 && environment.reflection.x > 0.5 && environment.reflectionQuality.y > 0.0 {
            let response = sampleAt(reflectionResponse, gBufferSampler, uv).rgb * ao;
            if max(response.r, max(response.g, response.b)) > MINIMUM_TRACED_REFLECTIVITY {
                let hit = traceReflection(position + normal * environment.reflection.w, reflectionDirection);
                if hit.visible {
                    let weight = edgeVisibility(hit.uv) * clamp(environment.reflectionQuality.y, 0.0, 1.0);
                    let previous = probeReflection(position, reflectionDirection, roughness);
                    baseColor = max(baseColor + (blurredScene(hit.uv, roughness) - previous) * response * weight, vec3f(0.0));
                }
            }
        }
        return composite(baseColor, position, 1.0, false, input);
    }
    // Baked diffuse light already supplies ambient illumination.
    if environment.diffuseGI.z > 0.5 {
        return composite(baseColor, position, 1.0, false, input);
    }
    let sky = sampleSky(reflectionDirection);
    let fresnel = pow(1.0 - clamp(dot(-viewDirection, normal), 0.0, 1.0), 5.0);
    var reflectivity = mix(0.04, 1.0, metallic) * mix(1.0, fresnel, 0.35);
    reflectivity *= (1.0 - roughness * 0.7) * environment.reflectionQuality.y;
    var reflectedColor = sky;
    var visibility = 0.0;
    if environment.reflection.x > 0.5 && reflectivity * ao > MINIMUM_TRACED_REFLECTIVITY {
        let hit = traceReflection(position + normal * environment.reflection.w, reflectionDirection);
        if hit.visible {
            reflectedColor = blurredScene(hit.uv, roughness);
            visibility = edgeVisibility(hit.uv);
        }
    }
    let ambient = sampleSky(normal) * (0.035 + 0.035 * (1.0 - roughness));
    let reflectionResult = mix(sky, reflectedColor, visibility);
    return composite(baseColor + (ambient + reflectionResult * reflectivity) * ao, position, 1.0, false, input);
}
