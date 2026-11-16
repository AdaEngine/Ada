import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, linearSampler, transmittanceToSun, skyViewDirectionToUv, hitsGround, distanceToGround};
import package::clouds_common::{clouds, skyViewImage, cloudDensity, cloudPhase, raySphere, finishCloud, MAX_DISTANCE_FADE};

// The cheap cloud tier: one shaded 2D layer in the middle of the slab, with no raymarch. It uses the same noise,
// coverage and wind as the raymarched clouds, so a scene authored on desktop keeps its look in the browser.
@vertex
fn clouds_layer_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn clouds_layer_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let ground = atmosphere.planet.x;
    let cameraRadius = ground + max(atmosphere.planet.w, 0.5);
    let origin = vec3f(0.0, cameraRadius, 0.0);
    let ndc = vec2f(input.uv.x * 2.0 - 1.0, 1.0 - input.uv.y * 2.0);
    let viewFar = atmosphere.inverseProjection * vec4f(ndc, 1.0, 1.0);
    let viewRay = normalize(viewFar.xyz / viewFar.w);
    let direction = normalize((atmosphere.inverseView * vec4f(viewRay, 0.0)).xyz);
    var groundLimit = 1.0e9;
    if hitsGround(cameraRadius, direction.y) {
        groundLimit = distanceToGround(cameraRadius, direction.y);
    }
    let innerRadius = ground + clouds.layer.x;
    let thickness = clouds.layer.y;
    let middle = innerRadius + thickness * 0.5;
    let hit = raySphere(origin, direction, middle);
    // Below the layer the ray leaves the sphere on its far side; above it the ray enters on the near side.
    let distance = select(hit.x, hit.y, cameraRadius < middle);
    if hit.y < 0.0 || distance <= 0.0 || distance >= groundLimit || distance > MAX_DISTANCE_FADE * 2.0 {
        return vec4f(0.0, 0.0, 0.0, 1.0);
    }
    let point = origin + direction * distance;
    // A fixed height inside the slab: the layer has the weather, shape and gradient of the real clouds at one level.
    let density = cloudDensity(point, 0.15, false);
    // Grazing rays cross more cloud, so the layer gets more opaque toward the horizon.
    let slant = clamp(1.0 / max(abs(direction.y), 0.12), 1.0, 5.0);
    let opacity = smoothstep(0.55, 1.0, density * clouds.shape.y * min(slant, 2.0));
    if opacity <= 0.0 {
        return vec4f(0.0, 0.0, 0.0, 1.0);
    }
    let sunDirection = atmosphere.sunDirection.xyz;
    let radius = length(point);
    let sun = atmosphere.sunIlluminance.rgb * transmittanceToSun(radius, dot(point / radius, sunDirection));
    let zenithUV = skyViewDirectionToUv(vec3f(0.0, 1.0, 0.0), cameraRadius);
    let ambient = textureSampleLevel(skyViewImage, linearSampler, zenithUV, 0.0).rgb * clouds.layer.w * 0.7;
    let phase = cloudPhase(dot(direction, sunDirection), 1.0);
    // Thick parts of the layer shade darker, which gives the flat layer some body.
    let body = 1.0 - 0.45 * smoothstep(0.3, 1.0, density);
    let direct = sun * (phase * 4.0 * clouds.layer.z * body);
    return finishCloud((direct + ambient) * opacity, opacity, distance, distance, input.uv);
}
