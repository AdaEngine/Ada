// WESL port of Public/BakedDiffuse3D.glsl. All RGB values are diffuse irradiance / pi.
// Features: ADA_LIGHTMAP, ADA_IRRADIANCE_GRID. The IBL sampler and the lightmap parameters come from the caller.

struct IrradianceGrid3DUniform {
    u_GridOriginIntensity: vec4f,
    u_GridSpacingNormalBias: vec4f,
    u_GridCountsVisibilityBias: vec4f,
    u_GridQuality: vec4f,
}

@if(ADA_LIGHTMAP) @group(0) @binding(46) var u_DiffuseLightmap: texture_2d<f32>;
@if(ADA_LIGHTMAP) @group(0) @binding(47) var u_LightmapSampler: sampler;
@if(ADA_IRRADIANCE_GRID) @group(0) @binding(43) var u_ProbeSH: texture_2d<f32>;
@if(ADA_IRRADIANCE_GRID) @group(0) @binding(44) var u_ProbeVisibility: texture_2d<f32>;
@if(ADA_IRRADIANCE_GRID) @group(0) @binding(48) var u_DynamicProbeSH: texture_2d<f32>;
@if(ADA_IRRADIANCE_GRID) @group(0) @binding(45) var<uniform> irradianceGrid: IrradianceGrid3DUniform;

@if(ADA_IRRADIANCE_GRID)
fn adaOctEncode(direction: vec3f) -> vec2f {
    var d = direction / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 0.000001);
    if d.z < 0.0 {
        let folded = (vec2f(1.0) - abs(d.yx)) * select(vec2f(-1.0), vec2f(1.0), d.xy >= vec2f(0.0));
        d = vec3f(folded, d.z);
    }
    return d.xy * 0.5 + vec2f(0.5);
}

// Probe loads use textureLoad, so no sampler is needed; dynamicOnly skips the baked coefficients.
@if(ADA_IRRADIANCE_GRID)
fn adaProbeSH(address: vec2i, n: vec3f, dynamicOnly: bool) -> vec3f {
    var basis = array<f32, 9>(
        0.2820947918, 0.4886025119 * n.y, 0.4886025119 * n.z, 0.4886025119 * n.x,
        1.0925484306 * n.x * n.y, 1.0925484306 * n.y * n.z, 0.3153915653 * (3.0 * n.z * n.z - 1.0),
        1.0925484306 * n.x * n.z, 0.5462742153 * (n.x * n.x - n.y * n.y)
    );
    var value = vec3f(0.0);
    for (var i = 0; i < 9; i++) {
        if !dynamicOnly {
            value += textureLoad(u_ProbeSH, address + vec2i(i, 0), 0).rgb * basis[i];
        }
        if irradianceGrid.u_GridQuality.w > 0.5 {
            value += textureLoad(u_DynamicProbeSH, address + vec2i(i, 0), 0).rgb * basis[i];
        }
    }
    return max(value, vec3f(0.0));
}

@if(ADA_IRRADIANCE_GRID)
fn adaIrradianceGrid(world: vec3f, normal: vec3f, dynamicOnly: bool) -> vec4f {
    let grid = irradianceGrid;
    if grid.u_GridQuality.y < 0.5 {
        return vec4f(0.0);
    }
    let local = (world - grid.u_GridOriginIntensity.xyz) / grid.u_GridSpacingNormalBias.xyz;
    let counts = grid.u_GridCountsVisibilityBias.xyz;
    if any(local < vec3f(0.0)) || any(local > counts - vec3f(1.0)) {
        return vec4f(0.0);
    }
    let cell = clamp(vec3i(floor(local)), vec3i(0), vec3i(counts) - vec3i(2));
    let blend = clamp(local - vec3f(cell), vec3f(0.0), vec3f(1.0));
    let edge = min(local, counts - vec3f(1.0) - local);
    let coverage = clamp(min(edge.x, min(edge.y, edge.z)) * 2.0, 0.0, 1.0);
    let biased = world + normal * grid.u_GridSpacingNormalBias.w;
    var sum = vec3f(0.0);
    var weights = 0.0;
    let resolution = i32(grid.u_GridQuality.x);
    let rows = i32(counts.y);
    for (var z = 0; z < 2; z++) {
        for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
                let probe = cell + vec3i(x, y, z);
                let shAddress = vec2i(probe.x * 9, probe.z * rows + probe.y);
                let valid = textureLoad(u_ProbeSH, shAddress, 0).a;
                if valid < 0.5 {
                    continue;
                }
                let position = grid.u_GridOriginIntensity.xyz + vec3f(probe) * grid.u_GridSpacingNormalBias.xyz;
                let delta = biased - position;
                let distance = length(delta);
                let uv = clamp(vec2i(adaOctEncode(delta) * f32(resolution)), vec2i(0), vec2i(resolution - 1));
                let address = vec2i(probe.x, probe.z * rows + probe.y) * resolution + uv;
                let moments = textureLoad(u_ProbeVisibility, address, 0).rgb;
                let difference = max(distance - moments.x - grid.u_GridCountsVisibilityBias.w, 0.0);
                let variance = max(moments.y - moments.x * moments.x, 0.0);
                var visibility = select(variance / max(variance + difference * difference, 0.000001), 1.0, difference <= 0.0);
                visibility = pow(clamp(visibility, 0.0, 1.0), grid.u_GridQuality.z);
                // Reject near-zero weights instead of introducing a light-leaking minimum weight.
                visibility = max(visibility - 0.05, 0.0) / 0.95;
                let factors = mix(vec3f(1.0) - blend, blend, vec3f(f32(x), f32(y), f32(z)));
                let weight = factors.x * factors.y * factors.z * visibility;
                sum += adaProbeSH(shAddress, normal, dynamicOnly) * weight;
                weights += weight;
            }
        }
    }
    // An interior point with no visible valid probe stays dark, rather than falling back to leaking global IBL.
    let irradiance = select(vec3f(0.0), sum / weights * grid.u_GridOriginIntensity.w, weights > 0.000001);
    return vec4f(irradiance, coverage);
}

fn adaBakedDiffuse(world: vec3f, normal: vec3f, uv1: vec2f, lightmapScaleOffset: vec4f, bakedParameters: vec4f) -> vec4f {
    var lightmap = vec4f(0.0);
    @if(ADA_LIGHTMAP) {
        let size = vec2f(textureDimensions(u_DiffuseLightmap, 0));
        let uv = clamp(uv1 * lightmapScaleOffset.xy + lightmapScaleOffset.zw, vec2f(0.5) / size, vec2f(1.0) - vec2f(0.5) / size);
        lightmap = textureSampleLevel(u_DiffuseLightmap, u_LightmapSampler, uv, 0.0);
        lightmap = vec4f(lightmap.rgb * bakedParameters.x, clamp(lightmap.a, 0.0, 1.0));
        if lightmap.a >= 0.999 {
            @if(ADA_IRRADIANCE_GRID) {
                if irradianceGrid.u_GridQuality.w > 0.5 {
                    let dynamicLight = adaIrradianceGrid(world, normal, true);
                    lightmap = vec4f(lightmap.rgb + dynamicLight.rgb * dynamicLight.a, lightmap.a);
                }
            }
            return lightmap;
        }
    }
    @if(ADA_IRRADIANCE_GRID) {
        let grid = adaIrradianceGrid(world, normal, false);
        let coverage = lightmap.a + (1.0 - lightmap.a) * grid.a;
        let value = lightmap.rgb * lightmap.a + grid.rgb * (1.0 - lightmap.a) * grid.a;
        return vec4f(value / max(coverage, 0.000001), coverage);
    }
    return lightmap;
}
