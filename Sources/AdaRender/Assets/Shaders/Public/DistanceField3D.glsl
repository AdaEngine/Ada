// World-space SDF shadow queries. R32F node samples, tiled Z slices, no filtering across slices.
// The caller supplies its existing nearest sampler as u_DirectionalShadowSampler.
layout(binding=49) uniform texture2D u_DistanceFieldTexture;
layout(binding=50) uniform DistanceField3DUniform {
    vec4 u_SDFMinimumVoxel;   // world minimum.xyz, cubic voxel size
    vec4 u_SDFCountsDistance; // sample counts.xyz, maximum shadow ray distance
    vec4 u_SDFTrace;          // maximum steps, normal bias, cone tangent, 0 off / 1 shadows / 2 debug
};

float adaDistanceFieldNode(ivec3 p) {
    int nx = int(u_SDFCountsDistance.x), ny = int(u_SDFCountsDistance.y);
    int columns = max(textureSize(sampler2D(u_DistanceFieldTexture, u_DirectionalShadowSampler), 0).x / nx, 1);
    ivec2 address = ivec2(p.x + (p.z % columns) * nx, p.y + (p.z / columns) * ny);
    return texelFetch(sampler2D(u_DistanceFieldTexture, u_DirectionalShadowSampler), address, 0).r;
}

float adaDistanceFieldSample(vec3 world) {
    vec3 p = clamp((world - u_SDFMinimumVoxel.xyz) / u_SDFMinimumVoxel.w,
        vec3(0.0), u_SDFCountsDistance.xyz - 1.0);
    ivec3 cell = min(ivec3(floor(p)), ivec3(u_SDFCountsDistance.xyz) - 2);
    vec3 f = p - vec3(cell);
    float a = mix(adaDistanceFieldNode(cell), adaDistanceFieldNode(cell + ivec3(1,0,0)), f.x);
    float b = mix(adaDistanceFieldNode(cell + ivec3(0,1,0)), adaDistanceFieldNode(cell + ivec3(1,1,0)), f.x);
    float c = mix(adaDistanceFieldNode(cell + ivec3(0,0,1)), adaDistanceFieldNode(cell + ivec3(1,0,1)), f.x);
    float d = mix(adaDistanceFieldNode(cell + ivec3(0,1,1)), adaDistanceFieldNode(cell + ivec3(1,1,1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

// Clip the trace to the known field. Geometry outside that bounded domain is left to ordinary shadow maps.
bool adaDistanceFieldInterval(vec3 origin, vec3 direction, float limit, out float enter, out float leave) {
    vec3 maximum = u_SDFMinimumVoxel.xyz + (u_SDFCountsDistance.xyz - 1.0) * u_SDFMinimumVoxel.w;
    enter = 0.0; leave = limit;
    for (int axis = 0; axis < 3; ++axis) {
        if (abs(direction[axis]) < 0.000001) {
            if (origin[axis] < u_SDFMinimumVoxel[axis] || origin[axis] > maximum[axis]) { return false; }
        } else {
            float a = (u_SDFMinimumVoxel[axis] - origin[axis]) / direction[axis];
            float b = (maximum[axis] - origin[axis]) / direction[axis];
            enter = max(enter, min(a, b)); leave = min(leave, max(a, b));
            if (leave < enter) { return false; }
        }
    }
    return leave > enter;
}

float adaDistanceFieldVisibility(vec3 world, vec3 normal, vec3 direction, float maximumDistance) {
    if (u_SDFTrace.w < 0.5) { return 1.0; }
    float voxel = u_SDFMinimumVoxel.w;
    // The weighted interpolation error of a 1-Lipschitz distance function is
    // bounded by half a voxel diagonal. Keep that margin in both hit tests and
    // advancement, retaining sub-voxel blockers instead of stepping through them.
    float margin = voxel * 0.866025404;
    float epsilon = voxel * 0.025;
    vec3 origin = world + normal * max(u_SDFTrace.y, margin + epsilon * 2.0);
    float travel, end;
    if (!adaDistanceFieldInterval(origin, direction, min(maximumDistance, u_SDFCountsDistance.w), travel, end)) { return 1.0; }
    float visibility = 1.0;
    int steps = int(u_SDFTrace.x);
    for (int step = 0; step < 128; ++step) {
        if (travel >= end) { return clamp(visibility, 0.0, 1.0); }
        if (step >= steps) { break; }
        float distance = adaDistanceFieldSample(origin + direction * travel) - margin;
        if (distance <= epsilon) { return 0.0; }
        if (u_SDFTrace.z > 0.00001) {
            visibility = min(visibility, distance / max(travel * u_SDFTrace.z, epsilon));
        }
        travel += max(distance * 0.8, epsilon);
    }
    // An unresolved trace is not evidence of an unobstructed light path.
    return travel >= end ? clamp(visibility, 0.0, 1.0) : 0.0;
}
