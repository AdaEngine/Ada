import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::clouds_noise_common::{atlasCoordinate, worleyNoise, gradientNoise};

@vertex
fn clouds_noise_weather_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn clouds_noise_weather_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let p = atlasCoordinate(input.position.xy);
    let coverage = gradientNoise(vec3f(p.xy * 4.0, 1.48), 4) * 0.6
        + gradientNoise(vec3f(p.xy * 8.0, 2.96), 8) * 0.3
        + gradientNoise(vec3f(p.xy * 16.0, 5.92), 16) * 0.1;
    let kind = gradientNoise(vec3f(p.xy * 3.0, 2.4), 3);
    let pattern = worleyNoise(vec3f(p.xy * 6.0, 2.2), 6);
    return vec4f(coverage, kind, pattern, 1.0);
}
