#if canImport(Metal)
    enum MetalVisibilityShaders {
        static let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void visibility_copy(texture2d<float, access::read> src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
                if (p.x < dst.get_width() && p.y < dst.get_height()) dst.write(float4(src.read(p).x), p);
            }
            kernel void visibility_reduce(texture2d<float, access::read> src [[texture(0)]],
                                          texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
                if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
                uint2 lo = p * 2, hi = min(lo + 2, uint2(src.get_width(), src.get_height()));
                // Floor-sized mip levels must include the final row/column of odd input sizes.
                if (p.x + 1 == dst.get_width()) hi.x = src.get_width();
                if (p.y + 1 == dst.get_height()) hi.y = src.get_height();
                float farthest = 0;
                for (uint y = lo.y; y < hi.y; ++y) for (uint x = lo.x; x < hi.x; ++x)
                    farthest = max(farthest, src.read(uint2(x, y)).x);
                dst.write(float4(farthest), p);
            }
            struct Candidate { float4 minimum; float4 maximum; uint draw; uint source; uint destination; uint forceVisible; };
            struct View { float4x4 projection; uint width; uint height; uint count; uint words; };
            struct Draw { uint indexCount; atomic_uint instanceCount; uint firstIndex; int baseVertex; uint firstInstance; };
            bool visible(Candidate c, constant View &v, texture2d<float, access::read> depth) {
                if (c.forceVisible || !all(isfinite(c.minimum.xyz)) || !all(isfinite(c.maximum.xyz))) return true;
                float2 lo = float2(1e20), hi = float2(-1e20); float nearest = 1;
                for (uint corner = 0; corner < 8; ++corner) {
                    float3 p = float3(corner & 1 ? c.maximum.x : c.minimum.x,
                                     corner & 2 ? c.maximum.y : c.minimum.y,
                                     corner & 4 ? c.maximum.z : c.minimum.z);
                    float4 clip = v.projection * float4(p, 1);
                    // Near-plane intersections and invalid projections are never occlusion-rejected.
                    if (!all(isfinite(clip)) || clip.w <= 0 || clip.z <= 0) return true;
                    float3 ndc = clip.xyz / clip.w;
                    float2 pixel = (ndc.xy * float2(0.5, -0.5) + 0.5) * float2(v.width, v.height);
                    lo = min(lo, pixel); hi = max(hi, pixel); nearest = min(nearest, ndc.z);
                }
                lo = clamp(lo - 2, float2(0), float2(v.width - 1, v.height - 1));
                hi = clamp(hi + 2, float2(0), float2(v.width - 1, v.height - 1));
                uint level = min(uint(ceil(log2(max(max(hi.x - lo.x, hi.y - lo.y), 1.0)))), depth.get_num_mip_levels() - 1);
                uint step = 1u << level;
                uint2 last = uint2(depth.get_width(level), depth.get_height(level)) - 1;
                uint2 first = min(uint2(floor(lo / float(step))), last);
                uint2 end = min(uint2(floor(hi / float(step))), last);
                float farthest = 0;
                for (uint y = first.y; y <= end.y; ++y) for (uint x = first.x; x <= end.x; ++x)
                    farthest = max(farthest, depth.read(uint2(x, y), level).x);
                return nearest <= farthest + 0.0005;
            }
            kernel void visibility_compact(device const Candidate *candidates [[buffer(0)]],
                                           device const uint *input [[buffer(1)]], device uint *output [[buffer(2)]],
                                           device Draw *draws [[buffer(3)]], constant View &view [[buffer(4)]],
                                           texture2d<float, access::read> depth [[texture(0)]], uint i [[thread_position_in_grid]]) {
                if (i >= view.count) return;
                Candidate c = candidates[i];
                if (!visible(c, view, depth)) return;
                uint destination = c.destination + atomic_fetch_add_explicit(&draws[c.draw].instanceCount, 1u, memory_order_relaxed);
                for (uint word = 0; word < view.words; ++word) output[destination * view.words + word] = input[c.source * view.words + word];
            }
            """
    }
#endif
