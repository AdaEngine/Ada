import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, sampleMedium, transmittanceUvToParams, distanceToTop};

@vertex
fn atmosphere_transmittance_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

// Optical depth from every (radius, zenith cosine) to the top of the atmosphere.
@fragment
fn atmosphere_transmittance_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let params = transmittanceUvToParams(input.uv);
    let r = params.x;
    let mu = params.y;
    let stepCount = i32(atmosphere.steps.x);
    let length = distanceToTop(r, mu);
    let stepLength = length / f32(stepCount);
    var depth = vec3f(0.0);
    for (var index = 0; index < 128; index++) {
        if index >= stepCount { break; }
        let travel = (f32(index) + 0.5) * stepLength;
        let radius = sqrt(r * r + travel * travel + 2.0 * r * mu * travel);
        depth += sampleMedium(radius - atmosphere.planet.x).extinction * stepLength;
    }
    return vec4f(exp(-depth), 1.0);
}
