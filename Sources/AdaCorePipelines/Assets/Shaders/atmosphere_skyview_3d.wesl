import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::atmosphere_common::{atmosphere, skyViewUvToDirection, integrateScattering, hitsGround, distanceToGround, distanceToTop};

@vertex
fn atmosphere_skyview_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

// Sky radiance for every view direction from the camera, parametrized around the horizon and the sun azimuth.
@fragment
fn atmosphere_skyview_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let r = atmosphere.planet.x + max(atmosphere.planet.w, 0.5);
    let direction = skyViewUvToDirection(input.uv, r);
    let touchesGround = hitsGround(r, direction.y);
    let maxDistance = select(distanceToTop(r, direction.y), distanceToGround(r, direction.y), touchesGround);
    let result = integrateScattering(vec3f(0.0, r, 0.0), direction, maxDistance, i32(atmosphere.steps.y), touchesGround);
    return vec4f(result.luminance, (result.throughput.r + result.throughput.g + result.throughput.b) / 3.0);
}
