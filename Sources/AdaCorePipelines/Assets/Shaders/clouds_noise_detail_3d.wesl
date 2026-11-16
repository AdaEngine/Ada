import package::fullscreen::{FullscreenVertex, fullscreenVertex};
import package::clouds_noise_common::{atlasCoordinate, worleyNoise};

@vertex
fn clouds_noise_detail_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

@fragment
fn clouds_noise_detail_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let p = atlasCoordinate(input.position.xy);
    return vec4f(worleyNoise(p * 2.0, 2), worleyNoise(p * 4.0, 4), worleyNoise(p * 8.0, 8), 1.0);
}
