#if WEBGPU_ENABLED && canImport(WebGPU)
    enum WGPUShadowCullShaders {
        /// One thread per (view, caster). Mirrors `MeshVisibilityFrustum3D.intersects` with a relative tolerance
        /// toward drawing, so GPU float differences can only add (harmless) draws, never drop one.
        static let cull = """
            struct Caster {
                minimum: vec4f, maximum: vec4f, part: u32, instance: u32, fadeDistance: f32, pad: u32,
                distanceCenter: vec4f,
            }
            struct View {
                planes: array<vec4f, 6>, culls: u32, pad0: u32, pad1: u32, pad2: u32,
                distanceCamera: vec4f,
            }
            struct Params {
                casterCount: u32, viewCount: u32, partCount: u32, strideWords: u32,
                copiedWords: u32, distanceFadeWord: u32, pad1: u32, pad2: u32,
            }
            struct Draw {
                indexCount: u32, instanceCount: atomic<u32>, firstIndex: u32, baseVertex: i32, firstInstance: u32,
            }
            @group(0) @binding(0) var<storage, read> casters: array<Caster>;
            @group(0) @binding(1) var<storage, read> views: array<View>;
            @group(0) @binding(2) var<storage, read> segments: array<u32>;
            @group(0) @binding(3) var<storage, read> instanceInput: array<u32>;
            @group(0) @binding(4) var<storage, read_write> instanceOutput: array<u32>;
            @group(0) @binding(5) var<storage, read_write> draws: array<Draw>;
            @group(0) @binding(6) var<uniform> params: Params;
            fn finite(v: vec4f) -> bool {
                return all((bitcast<vec4u>(v) & vec4u(0x7fffffffu)) < vec4u(0x7f800000u));
            }
            fn visible(c: Caster, view: View) -> bool {
                if (view.culls == 0u || c.minimum.w != 0.0) { return true; }
                let center = (c.minimum.xyz + c.maximum.xyz) * 0.5;
                let half = (c.maximum.xyz - c.minimum.xyz) * 0.5;
                if (!finite(vec4f(center, 1.0)) || !finite(vec4f(half, 1.0))) { return true; }
                for (var i = 0u; i < 6u; i++) {
                    let plane = view.planes[i];
                    let radius = dot(abs(plane.xyz), half);
                    let distance = dot(plane.xyz, center) + plane.w + radius;
                    let scale = dot(abs(plane.xyz), abs(center) + half) + abs(plane.w);
                    if (!finite(vec4f(distance, scale, 0.0, 1.0))) { return true; }
                    if (distance < -0.0001 - scale * 0.00001) { return false; }
                }
                return true;
            }
            @compute @workgroup_size(64)
            fn main(@builtin(global_invocation_id) id: vec3u, @builtin(num_workgroups) groups: vec3u) {
                let i = id.x + id.y * groups.x * 64u;
                if (i >= params.casterCount * params.viewCount) { return; }
                let v = i / params.casterCount;
                let c = casters[i % params.casterCount];
                let view = views[v];
                if (!visible(c, view)) { return; }
                var removed = 0.0;
                if (view.distanceCamera.w != 0.0 && c.maximum.w > 0.0) {
                    let distance = length(c.distanceCenter.xyz - view.distanceCamera.xyz);
                    if (distance >= c.maximum.w) { return; }
                    if (c.fadeDistance > 0.0) {
                        removed = 1.0 - clamp((c.maximum.w - distance) / c.fadeDistance, 0.0, 1.0);
                    }
                }
                let draw = v * params.partCount + c.part;
                let destination = v * params.casterCount + segments[c.part] + atomicAdd(&draws[draw].instanceCount, 1u);
                let source = c.instance * params.strideWords;
                let output = destination * params.strideWords;
                for (var word = 0u; word < params.copiedWords; word++) {
                    instanceOutput[output + word] = instanceInput[source + word];
                }
                if (params.distanceFadeWord < params.copiedWords && removed > 0.0) {
                    instanceOutput[output + params.distanceFadeWord] = bitcast<u32>(removed);
                }
            }
            """
    }
#endif
