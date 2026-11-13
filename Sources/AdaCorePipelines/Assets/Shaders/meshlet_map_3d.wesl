import ada_engine::view::{view, projectPosition};
import package::mesh_visibility::meshOrientation;

struct MapInput {
    @location(0) positionAndID: vec4f,
    @location(5) model0: vec4f,
    @location(6) model1: vec4f,
    @location(7) model2: vec4f,
    @location(8) model3: vec4f,
}

struct MapVertex {
    @builtin(position) position: vec4f,
    @location(0) @interpolate(flat) color: vec3f,
    @location(1) @interpolate(flat) orientation: f32,
    @location(2) viewPosition: vec3f,
}

struct MapOutput {
    @location(0) color: vec4f,
    @location(1) normal: vec4f,
    @location(2) position: vec4f,
    @location(3) indirect: vec4f,
    @if(MAP_RESPONSE) @location(4) response: vec4f,
    @if(MAP_SURFACE && MAP_RESPONSE) @location(5) surface: vec4f,
    @if(MAP_SURFACE && !MAP_RESPONSE) @location(4) surface: vec4f,
}

struct MapFlags {
    value: vec4f,
}

@group(0) @binding(54) var<uniform> flags: MapFlags;

@vertex
fn meshlet_map_vertex(input: MapInput) -> MapVertex {
    let model = mat4x4f(input.model0, input.model1, input.model2, input.model3);
    let world = model * vec4f(input.positionAndID.xyz, 1.0);
    let encodedID = u32(input.positionAndID.w);
    let level = encodedID >> 20u;
    var id = (encodedID & 1048575u) + 1u;
    id ^= id >> 16u;
    id *= 2146121005u;
    id ^= id >> 15u;
    id *= 2221713035u;
    id ^= id >> 16u;
    let channels = vec3u(id & 255u, (id >> 8u) & 255u, (id >> 16u) & 255u);
    var color = vec3f(0.2) + 0.8 * vec3f(channels) / 255.0;
    if level > 0u {
        let palette = array<vec3f, 6>(
            vec3f(0.2, 0.85, 1.0), vec3f(0.95, 0.45, 0.1), vec3f(0.9, 0.2, 0.7),
            vec3f(0.5, 0.35, 1.0), vec3f(1.0, 0.85, 0.15), vec3f(0.3, 1.0, 0.4),
        );
        color = mix(color, palette[(level - 1u) % 6u], 0.7);
    }
    return MapVertex(projectPosition(world), color, meshOrientation(model), (view.viewMatrix * world).xyz);
}

@fragment
fn meshlet_map_fragment(input: MapVertex, @builtin(front_facing) frontFacing: bool) -> MapOutput {
    let normal = normalize(cross(dpdx(input.viewPosition), dpdy(input.viewPosition)));
    let front = select(frontFacing, !frontFacing, input.orientation < 0.0);
    if flags.value.x < 0.5 && !front {
        discard;
    }
    var output: MapOutput;
    output.color = vec4f(input.color, 1.0);
    output.normal = vec4f(normal, 1.0);
    output.position = vec4f(input.viewPosition, 0.0);
    output.indirect = vec4f(0.0);
    @if(MAP_RESPONSE) output.response = vec4f(0.0);
    @if(MAP_SURFACE) output.surface = vec4f(0.0);
    return output;
}
