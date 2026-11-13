// WESL port of Public/DistanceField3D.glsl: world-space SDF shadow queries over R32F node samples in tiled Z slices.
// The caller supplies its nearest sampler (the GLSL path reused u_DirectionalShadowSampler).

struct DistanceField3DUniform {
    u_SDFMinimumVoxel: vec4f,    // world minimum.xyz, cubic voxel size
    u_SDFCountsDistance: vec4f,  // sample counts.xyz, maximum shadow ray distance
    u_SDFTrace: vec4f,           // maximum steps, normal bias, cone tangent, 0 off / 1 shadows / 2 debug
}

@group(0) @binding(49) var u_DistanceFieldTexture: texture_2d<f32>;
@group(0) @binding(30) var<uniform> distanceField: DistanceField3DUniform;

fn adaDistanceFieldNode(p: vec3i) -> f32 {
    let nx = i32(distanceField.u_SDFCountsDistance.x);
    let ny = i32(distanceField.u_SDFCountsDistance.y);
    let columns = max(i32(textureDimensions(u_DistanceFieldTexture, 0).x) / nx, 1);
    let address = vec2i(p.x + (p.z % columns) * nx, p.y + (p.z / columns) * ny);
    return textureLoad(u_DistanceFieldTexture, address, 0).r;
}

fn adaDistanceFieldSample(world: vec3f) -> f32 {
    let counts = distanceField.u_SDFCountsDistance.xyz;
    let p = clamp(
        (world - distanceField.u_SDFMinimumVoxel.xyz) / distanceField.u_SDFMinimumVoxel.w,
        vec3f(0.0),
        counts - vec3f(1.0)
    );
    let cell = min(vec3i(floor(p)), vec3i(counts) - vec3i(2));
    let f = p - vec3f(cell);
    let a = mix(adaDistanceFieldNode(cell), adaDistanceFieldNode(cell + vec3i(1, 0, 0)), f.x);
    let b = mix(adaDistanceFieldNode(cell + vec3i(0, 1, 0)), adaDistanceFieldNode(cell + vec3i(1, 1, 0)), f.x);
    let c = mix(adaDistanceFieldNode(cell + vec3i(0, 0, 1)), adaDistanceFieldNode(cell + vec3i(1, 0, 1)), f.x);
    let d = mix(adaDistanceFieldNode(cell + vec3i(0, 1, 1)), adaDistanceFieldNode(cell + vec3i(1, 1, 1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

struct DistanceFieldInterval {
    valid: bool,
    enter: f32,
    leave: f32,
}

// Clip the trace to the known field. Geometry outside that bounded domain is left to ordinary shadow maps.
fn adaDistanceFieldInterval(origin: vec3f, direction: vec3f, limit: f32) -> DistanceFieldInterval {
    let minimum = distanceField.u_SDFMinimumVoxel.xyz;
    let maximum = minimum + (distanceField.u_SDFCountsDistance.xyz - vec3f(1.0)) * distanceField.u_SDFMinimumVoxel.w;
    var enter = 0.0;
    var leave = limit;
    for (var axis = 0; axis < 3; axis++) {
        if abs(direction[axis]) < 0.000001 {
            if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] {
                return DistanceFieldInterval(false, 0.0, 0.0);
            }
        } else {
            let a = (minimum[axis] - origin[axis]) / direction[axis];
            let b = (maximum[axis] - origin[axis]) / direction[axis];
            enter = max(enter, min(a, b));
            leave = min(leave, max(a, b));
            if leave < enter {
                return DistanceFieldInterval(false, 0.0, 0.0);
            }
        }
    }
    return DistanceFieldInterval(leave > enter, enter, leave);
}

fn adaDistanceFieldVisibility(world: vec3f, normal: vec3f, direction: vec3f, maximumDistance: f32) -> f32 {
    let trace = distanceField.u_SDFTrace;
    if trace.w < 0.5 {
        return 1.0;
    }
    let voxel = distanceField.u_SDFMinimumVoxel.w;
    // The weighted interpolation error of a 1-Lipschitz distance function is bounded by half a voxel diagonal.
    let margin = voxel * 0.866025404;
    let epsilon = voxel * 0.025;
    let origin = world + normal * max(trace.y, margin + epsilon * 2.0);
    let interval = adaDistanceFieldInterval(origin, direction, min(maximumDistance, distanceField.u_SDFCountsDistance.w));
    if !interval.valid {
        return 1.0;
    }
    var travel = interval.enter;
    var visibility = 1.0;
    let steps = i32(trace.x);
    for (var step = 0; step < 128; step++) {
        if travel >= interval.leave {
            return clamp(visibility, 0.0, 1.0);
        }
        if step >= steps {
            break;
        }
        let distance = adaDistanceFieldSample(origin + direction * travel) - margin;
        if distance <= epsilon {
            return 0.0;
        }
        if trace.z > 0.00001 {
            visibility = min(visibility, distance / max(travel * trace.z, epsilon));
        }
        travel += max(distance * 0.8, epsilon);
    }
    // An unresolved trace is not evidence of an unobstructed light path.
    return select(0.0, clamp(visibility, 0.0, 1.0), travel >= interval.leave);
}
