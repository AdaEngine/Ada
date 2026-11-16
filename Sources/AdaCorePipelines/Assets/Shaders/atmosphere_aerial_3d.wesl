import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, integrateScattering};

@vertex
fn atmosphere_aerial_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

struct AerialOutput {
    // rgb: light scattered into the view ray, a: mean transmittance.
    @location(0) scattering: vec4f,
    // rgb: per-channel transmittance of the path.
    @location(1) transmittance: vec4f,
}

// In-scattered light and transmittance from the camera to each depth slice. The slices of the volume are laid out
// side by side in one 2D target: slice i covers x in [i * tile, (i + 1) * tile).
@fragment
fn atmosphere_aerial_fragment(input: FullscreenVertex) -> AerialOutput {
    let tile = atmosphere.aerial.w;
    let slice = floor(input.position.x / tile);
    let uv = vec2f((input.position.x - slice * tile) / tile, input.position.y / tile);
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let viewFar = atmosphere.inverseProjection * vec4f(ndc, 1.0, 1.0);
    let viewRay = normalize(viewFar.xyz / viewFar.w);
    let direction = normalize((atmosphere.inverseView * vec4f(viewRay, 0.0)).xyz);
    let distance = atmosphere.aerial.x * (slice + 1.0) / atmosphere.aerial.z;
    let origin = vec3f(0.0, atmosphere.planet.x + max(atmosphere.planet.w, 0.5), 0.0);
    let result = integrateScattering(origin, direction, distance, i32(atmosphere.steps.z), false);
    let mean = (result.throughput.r + result.throughput.g + result.throughput.b) / 3.0;
    return AerialOutput(vec4f(result.luminance, mean), vec4f(result.throughput, 1.0));
}
