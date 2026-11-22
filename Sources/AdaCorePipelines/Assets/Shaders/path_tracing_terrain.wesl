// Layers use the same immutable fields as the raster terrain pass. In particular, interpolate
// coverage by palette ID, never the integer IDs themselves.
@group(0) @binding(17) var terrainFields: texture_2d<f32>;

struct TraceTerrainTexel {
    albedo: vec3f,
    normal: vec3f,
    orm: vec3f,
    height: f32,
}

struct TraceTerrainSurface {
    color: vec3f,
    normal: vec3f,
    roughness: f32,
    metal: f32,
}

fn terrainTableAt(table: texture_2d<f32>, index: i32) -> vec4f {
    return textureLoad(table, vec2i(index % 2048, index / 2048), 0);
}

fn terrainFieldAt(index: i32) -> vec4f {
    return terrainTableAt(terrainFields, index);
}

fn terrainColorLinear(color: vec3f) -> vec3f {
    return select(color / 12.92, pow((color + vec3f(0.055)) / 1.055, vec3f(2.4)), color > vec3f(0.04045));
}

fn terrainAtlas(paletteAtlas: texture_2d<f32>, linear: sampler, tile: f32, uv: vec2f) -> vec4f {
    let size = vec2f(textureDimensions(paletteAtlas, 0));
    let stride = size.x / 16.0;
    let pixel = clamp(fract(uv) * stride, vec2f(0.5), vec2f(stride - 0.5));
    let origin = vec2f(tile - 16.0 * floor(tile / 16.0), floor(tile / 16.0)) * stride;
    return textureSampleLevel(paletteAtlas, linear, (origin + pixel) / size, 0.0);
}

fn traceTerrainHash(cell: vec2f, seed: u32) -> u32 {
    let wrapped = cell - vec2f(16777216.0) * floor(cell / vec2f(16777216.0));
    let p = vec2u(wrapped);
    var h = seed ^ (p.x * 0x9e3779b9u) ^ (p.y * 0x85ebca6bu);
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    return h ^ (h >> 16u);
}

fn traceTerrainMacro(coordinate: vec2f, seed: u32) -> f32 {
    let cell = floor(coordinate);
    let f = smoothstep(vec2f(0.0), vec2f(1.0), fract(coordinate));
    let a = f32(traceTerrainHash(cell, seed) & 65535u) / 65535.0;
    let b = f32(traceTerrainHash(cell + vec2f(1.0, 0.0), seed) & 65535u) / 65535.0;
    let c = f32(traceTerrainHash(cell + vec2f(0.0, 1.0), seed) & 65535u) / 65535.0;
    let d = f32(traceTerrainHash(cell + vec2f(1.0), seed) & 65535u) / 65535.0;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fn readTraceTerrain(
    paletteAtlas: texture_2d<f32>, linear: sampler, tiles: vec3f, hasHeight: bool,
    uv: vec2f, transform: mat2x2f, offset: vec2f,
) -> TraceTerrainTexel {
    let q = transform * uv + offset;
    let albedo = terrainColorLinear(terrainAtlas(paletteAtlas, linear, tiles.x, q).rgb);
    let mapped = terrainAtlas(paletteAtlas, linear, tiles.y, q).xyz * 2.0 - vec3f(1.0);
    let normal = vec3f(transpose(transform) * mapped.xy, mapped.z);
    let orm = terrainAtlas(paletteAtlas, linear, tiles.z, q);
    return TraceTerrainTexel(albedo, normal, orm.rgb, select(0.5, orm.a, hasHeight));
}

fn sampleTraceTerrain(
    paletteAtlas: texture_2d<f32>, linear: sampler, tiles: vec3f, settings: vec4f, scales: vec4f,
    uv: vec2f, localPosition: vec2f,
) -> TraceTerrainTexel {
    let flags = u32(settings.x);
    let seed = u32(settings.y) | (u32(settings.z) << 16u);
    let identity = mat2x2f(1.0, 0.0, 0.0, 1.0);
    var result: TraceTerrainTexel;
    if scales.z > 0.5 || (flags & 16u) == 0u {
        result = readTraceTerrain(paletteAtlas, linear, tiles, scales.w > 0.5, select(uv, vec2f(0.5), scales.z > 0.5), identity, vec2f(0.0));
    } else {
        let coordinate = uv / scales.x;
        let cell = floor(coordinate);
        let f = smoothstep(vec2f(0.0), vec2f(1.0), fract(coordinate));
        for (var corner = 0; corner < 4; corner++) {
            let x = corner & 1;
            let y = corner >> 1u;
            let weight = select(f.x, 1.0 - f.x, x == 0) * select(f.y, 1.0 - f.y, y == 0);
            if weight <= 0.00001 { continue; }
            let random = traceTerrainHash(cell + vec2f(f32(x), f32(y)), seed);
            let flipU = select(1.0, -1.0, (flags & 1u) != 0u && (random & 1u) != 0u);
            let flipV = select(1.0, -1.0, (flags & 2u) != 0u && (random & 2u) != 0u);
            var transform = mat2x2f(flipU, 0.0, 0.0, flipV);
            let rotation = select(0u, (random >> 2u) & 3u, (flags & 4u) != 0u);
            if rotation == 1u { transform = mat2x2f(0.0, 1.0, -1.0, 0.0) * transform; }
            if rotation == 2u { transform *= -1.0; }
            if rotation == 3u { transform = mat2x2f(0.0, -1.0, 1.0, 0.0) * transform; }
            let offset = select(vec2f(0.0), vec2f(f32((random >> 8u) & 255u), f32((random >> 16u) & 255u)) / 256.0, (flags & 8u) != 0u);
            let value = readTraceTerrain(paletteAtlas, linear, tiles, scales.w > 0.5, uv, transform, offset);
            result.albedo += value.albedo * weight;
            result.normal += value.normal * weight;
            result.orm += value.orm * weight;
            result.height += value.height * weight;
        }
    }
    if settings.w > 0.0 {
        let macroValue = traceTerrainMacro(localPosition / scales.y, seed ^ 0x68bc21ebu);
        result.albedo = clamp(result.albedo * (1.0 + (macroValue * 2.0 - 1.0) * settings.w), vec3f(0.0), vec3f(1.0));
    }
    return result;
}

fn traceTerrainProjected(
    paletteAtlas: texture_2d<f32>, linear: sampler, tiles: vec3f, settings: vec4f, scales: vec4f,
    local: vec3f, position: vec3f, normal: vec3f,
) -> TraceTerrainTexel {
    var weights = pow(abs(normal), vec3f(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.00001);
    var result: TraceTerrainTexel;
    for (var axis = 0; axis < 3; axis++) {
        let weight = weights[axis];
        if weight <= 0.00001 { continue; }
        var uv = position.xy;
        if axis == 0 { uv = position.zy; }
        if axis == 1 { uv = position.xz; }
        let value = sampleTraceTerrain(paletteAtlas, linear, tiles, settings, scales, uv, local.xz);
        let mapped = select(vec3f(0.0, 0.0, 1.0), normalize(value.normal), length(value.normal) > 0.00001);
        var projected = vec3f(mapped.x + normal.x, mapped.y + normal.y, mapped.z * normal.z);
        if axis == 0 { projected = vec3f(mapped.z * normal.x, mapped.y + normal.y, mapped.x + normal.z); }
        if axis == 1 { projected = vec3f(mapped.x + normal.x, mapped.z * normal.y, mapped.y + normal.z); }
        result.albedo += value.albedo * weight;
        result.normal += projected * weight;
        result.orm += value.orm * weight;
        result.height += value.height * weight;
    }
    result.normal = select(normal, normalize(result.normal), length(result.normal) > 0.00001);
    return result;
}

fn traceTerrainMaterial(
    table: texture_2d<f32>, paletteAtlas: texture_2d<f32>, linear: sampler, header: i32,
    position: vec3f, fieldUV: vec2f, normal: vec3f, planarFrame: mat3x3f,
) -> TraceTerrainSurface {
    let gridInfo = terrainTableAt(table, header);
    let fieldInfo = vec4i(terrainTableAt(table, header + 1));
    let paintOffset = i32(terrainTableAt(table, header + 2).x);
    let volume = gridInfo.z < 0.0;
    let extent = fieldInfo.zw - vec2i(1);
    let grid = clamp(select((position.xz - gridInfo.xy) * gridInfo.z, fieldUV, volume), vec2f(0.0), vec2f(extent));
    let start = select(vec2i(floor(grid)), vec2i(floor(grid / 2.0)) * 2, volume);
    let fraction = select(fract(grid), clamp(grid - vec2f(start), vec2f(0.0), vec2f(1.0)), volume);
    var contributions: array<f32, 32>;
    var paint = vec4f(0.0);
    var roughnessMask = 0.0;
    if paintOffset < 0 { paint = vec4f(1.0, 1.0, 1.0, 0.0); }
    let layered = fieldInfo.x >= 0;
    if !layered { contributions[0] = 1.0; }
    if layered || paintOffset >= 0 {
        for (var z = 0; z < 2; z++) {
            for (var x = 0; x < 2; x++) {
                if volume && x == 1 && z == 1 { continue; }
                let at = min(start + vec2i(x, z), extent);
                let offset = at.y * fieldInfo.z + at.x;
                let bilinear = select(fraction.x, 1.0 - fraction.x, x == 0) * select(fraction.y, 1.0 - fraction.y, z == 0);
                let barycentric = select(select(max(0.0, 1.0 - fraction.x - fraction.y), fraction.y, z == 1), fraction.x, x == 1);
                let weight = select(bilinear, barycentric, volume);
                if layered {
                    let ids = vec4i(round(terrainFieldAt(fieldInfo.x + offset) * 255.0));
                    let weights = terrainFieldAt(fieldInfo.y + offset);
                    for (var channel = 0; channel < 4; channel++) {
                        contributions[clamp(ids[channel], 0, 31)] += weights[channel] * weight;
                    }
                }
                if paintOffset >= 0 {
                    paint += terrainFieldAt(paintOffset + offset) * weight;
                    roughnessMask += terrainFieldAt(paintOffset + fieldInfo.z * fieldInfo.w + offset).r * weight;
                }
            }
        }
    }

    var albedo = vec3f(0.0);
    var normals = vec3f(0.0);
    var pbr = vec2f(0.0);
    var total = 0.0;
    for (var outputSlot = 0; outputSlot < 4; outputSlot++) {
        var selected = 0;
        for (var layer = 1; layer < i32(gridInfo.w); layer++) {
            if contributions[layer] > contributions[selected] { selected = layer; }
        }
        let coverage = contributions[selected];
        if coverage <= 0.0 { break; }
        contributions[selected] = 0.0;
        let layer = header + 3 + selected * 5;
        let tint = terrainTableAt(table, layer);
        let pbrValues = terrainTableAt(table, layer + 1);
        let settings = terrainTableAt(table, layer + 2);
        let scales = terrainTableAt(table, layer + 3);
        let tiles = terrainTableAt(table, layer + 4).xyz;
        let samplePosition = position / select(pbrValues.z, 1.0, scales.z > 0.5);
        var texel: TraceTerrainTexel;
        var layerNormal: vec3f;
        if pbrValues.w > 0.5 {
            texel = traceTerrainProjected(paletteAtlas, linear, tiles, settings, scales, position, samplePosition, normal);
            layerNormal = texel.normal;
        } else {
            texel = sampleTraceTerrain(paletteAtlas, linear, tiles, settings, scales, samplePosition.xz, position.xz);
            layerNormal = planarFrame * texel.normal;
        }
        let weight = coverage * exp2(8.0 * (texel.height - 0.5));
        albedo += tint.rgb * texel.albedo * weight;
        normals += layerNormal * weight;
        pbr += pbrValues.xy * texel.orm.gb * weight;
        total += weight;
    }
    total = max(total, 0.00001);
    return TraceTerrainSurface(
        albedo * paint.rgb / total,
        select(normal, normalize(normals), length(normals) > 0.00001),
        clamp(pbr.x / total * (1.0 - roughnessMask) + paint.a, 0.04, 1.0),
        clamp(pbr.y / total, 0.0, 1.0),
    );
}
