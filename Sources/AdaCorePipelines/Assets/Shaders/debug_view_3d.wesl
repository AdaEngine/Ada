import package::fullscreen::{FullscreenVertex, fullscreenVertex};

struct DebugViewUniform {
    parameters: vec4f,
}

@group(0) @binding(0) var normalImage: texture_2d<f32>;
@group(0) @binding(1) var positionImage: texture_2d<f32>;
@group(0) @binding(2) var occlusionImage: texture_2d<f32>;
@group(0) @binding(3) var indirectImage: texture_2d<f32>;
@group(0) @binding(4) var nearestSampler: sampler;
@group(0) @binding(5) var<uniform> debugView: DebugViewUniform;
@group(0) @binding(6) var sceneColor: texture_2d<f32>;

@vertex
fn debug_view_vertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    return fullscreenVertex(index);
}

fn sampleAt(image: texture_2d<f32>, uv: vec2f) -> vec4f {
    return textureSampleLevel(image, nearestSampler, uv, 0.0);
}

@fragment
fn debug_view_fragment(input: FullscreenVertex) -> @location(0) vec4f {
    let uv = input.uv;
    let normalRoughness = sampleAt(normalImage, uv);
    let positionMetallic = sampleAt(positionImage, uv);
    // A zero normal marks pixels without geometry.
    let covered = length(normalRoughness.xyz) > 0.1;
    let mode = debugView.parameters.x;
    var color = vec3f(0.04);
    if mode < 1.5 {
        if covered {
            color = normalize(normalRoughness.xyz) * 0.5 + 0.5;
        }
    } else if mode < 2.5 {
        if covered {
            color = vec3f(1.0 - exp(-positionMetallic.z * debugView.parameters.y));
        }
    } else if mode < 3.5 {
        if covered {
            color = vec3f(normalRoughness.w);
        }
    } else if mode < 4.5 {
        if covered {
            color = vec3f(positionMetallic.w);
        }
    } else if mode < 5.5 {
        color = vec3f(sampleAt(occlusionImage, uv).r);
    } else if mode < 6.5 {
        if covered {
            color = vec3f(1.0) - exp(-sampleAt(indirectImage, uv).rgb * 24.0);
        }
    } else if covered {
        // Albedo, cascades, and light count are display-ready in scene color.
        color = clamp(sampleAt(sceneColor, uv).rgb, vec3f(0.0), vec3f(1.0));
    }
    return vec4f(color, 1.0);
}
