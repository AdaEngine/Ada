#if SAGA_NATIVE || SAGA_METAL
    enum SAGAVisibilityShaders {
        // Explicit unfilterable-float layouts allow rgba32float input without float32-filterable.
        static let copy = """
            @group(0) @binding(0) var source: texture_2d<f32>;
            @group(0) @binding(1) var destination: texture_storage_2d<r32float, write>;
            @compute @workgroup_size(8, 8)
            fn main(@builtin(global_invocation_id) id: vec3u) {
                if (any(id.xy >= textureDimensions(destination))) { return; }
                textureStore(destination, vec2i(id.xy), vec4f(textureLoad(source, vec2i(id.xy), 0).x));
            }
            """

        static let reduce = """
            @group(0) @binding(0) var source: texture_2d<f32>;
            @group(0) @binding(1) var destination: texture_storage_2d<r32float, write>;
            @compute @workgroup_size(8, 8)
            fn main(@builtin(global_invocation_id) id: vec3u) {
                let size = textureDimensions(destination);
                if (any(id.xy >= size)) { return; }
                let lo = id.xy * 2u;
                var hi = min(lo + 2u, textureDimensions(source));
                // Floor-sized mip levels must retain the last row/column of odd input sizes.
                if (id.x + 1u == size.x) { hi.x = textureDimensions(source).x; }
                if (id.y + 1u == size.y) { hi.y = textureDimensions(source).y; }
                var farthest = 0.0;
                for (var y = lo.y; y < hi.y; y++) {
                    for (var x = lo.x; x < hi.x; x++) {
                        farthest = max(farthest, textureLoad(source, vec2i(vec2u(x, y)), 0).x);
                    }
                }
                textureStore(destination, vec2i(id.xy), vec4f(farthest));
            }
            """

        static let compact = """
            struct Candidate {
                minimum: vec4f, maximum: vec4f,
                draw: u32, source: u32, destination: u32, forceVisible: u32,
            }
            struct View { projection: mat4x4f, width: u32, height: u32, count: u32, words: u32 }
            struct Draw {
                indexCount: u32, instanceCount: atomic<u32>, firstIndex: u32, baseVertex: i32, firstInstance: u32,
            }
            @group(0) @binding(0) var depth: texture_2d<f32>;
            @group(0) @binding(1) var<storage, read> candidates: array<Candidate>;
            @group(0) @binding(2) var<storage, read> instanceInput: array<u32>;
            @group(0) @binding(3) var<storage, read_write> instanceOutput: array<u32>;
            @group(0) @binding(4) var<storage, read_write> draws: array<Draw>;
            @group(0) @binding(5) var<uniform> view: View;
            fn finite(v: vec4f) -> bool {
                return all((bitcast<vec4u>(v) & vec4u(0x7fffffffu)) < vec4u(0x7f800000u));
            }
            fn visible(c: Candidate) -> bool {
                if (c.forceVisible != 0u || !finite(c.minimum) || !finite(c.maximum) || any(c.minimum.xyz > c.maximum.xyz)) { return true; }
                var lo = vec2f(1e20);
                var hi = vec2f(-1e20);
                var nearest = 1.0;
                for (var corner = 0u; corner < 8u; corner++) {
                    let p = vec3f(select(c.minimum.x, c.maximum.x, (corner & 1u) != 0u),
                                  select(c.minimum.y, c.maximum.y, (corner & 2u) != 0u),
                                  select(c.minimum.z, c.maximum.z, (corner & 4u) != 0u));
                    let clip = view.projection * vec4f(p, 1.0);
                    if (!finite(clip) || clip.w <= 0.0 || clip.z <= 0.0) { return true; }
                    let ndc = clip.xyz / clip.w;
                    if (!finite(vec4f(ndc, 1.0))) { return true; }
                    let pixel = (ndc.xy * vec2f(0.5, -0.5) + 0.5) * vec2f(f32(view.width), f32(view.height));
                    if (!finite(vec4f(pixel, 0.0, 1.0))) { return true; }
                    lo = min(lo, pixel);
                    hi = max(hi, pixel);
                    nearest = min(nearest, ndc.z);
                }
                let lastPixel = vec2f(f32(view.width - 1u), f32(view.height - 1u));
                lo = clamp(lo - 2.0, vec2f(0.0), lastPixel);
                hi = clamp(hi + 2.0, vec2f(0.0), lastPixel);
                let level = min(u32(ceil(log2(max(max(hi.x - lo.x, hi.y - lo.y), 1.0)))), textureNumLevels(depth) - 1u);
                let step = f32(1u << level);
                let last = textureDimensions(depth, level) - 1u;
                let first = min(vec2u(floor(lo / step)), last);
                let end = min(vec2u(floor(hi / step)), last);
                var farthest = 0.0;
                for (var y = first.y; y <= end.y; y++) {
                    for (var x = first.x; x <= end.x; x++) {
                        farthest = max(farthest, textureLoad(depth, vec2i(vec2u(x, y)), i32(level)).x);
                    }
                }
                return nearest <= farthest + 0.0005;
            }
            @compute @workgroup_size(64)
            fn main(@builtin(global_invocation_id) id: vec3u, @builtin(num_workgroups) groups: vec3u) {
                let i = id.x + id.y * groups.x * 64u;
                if (i >= view.count) { return; }
                let c = candidates[i];
                if (!visible(c)) { return; }
                let destination = c.destination + atomicAdd(&draws[c.draw].instanceCount, 1u);
                for (var word = 0u; word < view.words; word++) {
                    instanceOutput[destination * view.words + word] = instanceInput[c.source * view.words + word];
                }
            }
            """
    }
#endif
