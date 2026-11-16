import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::clouds_noise_common::{noise, atlasCoordinate, worleyNoise, gradientNoise};

@vertex
fn clouds_noise_shape_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn clouds_noise_shape_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let p = atlasCoordinate(input.position.xy);
    let w1 = worleyNoise(p * 4.0, 4);
    let w2 = worleyNoise(p * 8.0, 8);
    let w3 = worleyNoise(p * 16.0, 16);
    let fbm = w1 * 0.625 + w2 * 0.25 + w3 * 0.125;
    // Perlin-Worley: Perlin noise lifted by the Worley fbm, for billowy cloud bodies.
    let perlinWorley = fbm + gradientNoise(p * 4.0, 4) * (1.0 - fbm);
    return vec4f(perlinWorley, w1, w2, w3);
}
