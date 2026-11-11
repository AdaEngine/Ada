import ada_engine::view::projectPosition;

struct GradientVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

struct GradientUniform {
    startPoint: vec2f,
    endPoint: vec2f,
    stopCount: i32,
    colors: array<vec4f, 16>,
    locations: array<vec4f, 4>,
}

@group(0) @binding(0) var<uniform> gradient: GradientUniform;

@vertex
fn linear_gradient_vertex(@location(0) position: vec4f, @location(2) uv: vec2f) -> GradientVertex {
    return GradientVertex(projectPosition(position), uv);
}

fn stopLocation(index: i32) -> f32 {
    return gradient.locations[index / 4][index % 4];
}

fn gradientProgress(uv: vec2f) -> f32 {
    let axis = gradient.endPoint - gradient.startPoint;
    let lengthSquared = dot(axis, axis);
    if lengthSquared <= 0.000001 {
        return 1.0;
    }
    return clamp(dot(uv - gradient.startPoint, axis) / lengthSquared, 0.0, 1.0);
}

fn gradientColor(progress: f32) -> vec4f {
    let count = clamp(gradient.stopCount, 1, 16);
    var color = gradient.colors[0];
    var location = stopLocation(0);
    for (var index = 1; index < count; index++) {
        let nextColor = gradient.colors[index];
        let nextLocation = stopLocation(index);
        if progress <= nextLocation {
            let range = nextLocation - location;
            if range <= 0.000001 {
                return nextColor;
            }
            return mix(color, nextColor, clamp((progress - location) / range, 0.0, 1.0));
        }
        color = nextColor;
        location = nextLocation;
    }
    return color;
}

@fragment
fn linear_gradient_fragment(@location(0) uv: vec2f) -> @location(0) vec4f {
    let color = gradientColor(gradientProgress(uv));
    if color.a == 0.0 {
        discard;
    }
    return color;
}
