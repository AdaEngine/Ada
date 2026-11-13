import ada_engine::view::projectPosition;

// WESL port of agent_activity.glsl. Coordinates, size, radius and width are in logical pixels.
// The fragment returns PREMULTIPLIED RGBA; blend with ONE, ONE_MINUS_SRC_ALPHA.

struct EditorAgentGlowMaterial {
    u_Color: vec4f,
    u_Geometry: vec4f,
    u_Style: vec4f,
}

struct AgentGlowVertex {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@group(0) @binding(0) var<uniform> material: EditorAgentGlowMaterial;

@vertex
fn editor_agent_activity_vertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> AgentGlowVertex {
    return AgentGlowVertex(projectPosition(position), color, uv);
}

fn agentRGBToHSV(c: vec3f) -> vec3f {
    let k = vec4f(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    let p = mix(vec4f(c.bg, k.wz), vec4f(c.gb, k.xy), step(c.b, c.g));
    let q = mix(vec4f(p.xyw, c.r), vec4f(c.r, p.yzx), step(p.x, c.r));
    let d = q.x - min(q.w, q.y);
    return vec3f(abs(q.z + (q.w - q.y) / (6.0 * d + 0.00001)), d / (q.x + 0.00001), q.x);
}

fn agentHSVToRGB(c: vec3f) -> vec3f {
    let p = abs(fract(c.xxx + vec3f(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - vec3f(3.0));
    return c.z * mix(vec3f(1.0), clamp(p - vec3f(1.0), vec3f(0.0), vec3f(1.0)), c.y);
}

fn agentRoundedBox(p: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let q = abs(p) - halfSize + vec2f(radius);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

fn agentActivityGlow(
    position: vec2f, size: vec2f, time: f32, accent: vec3f,
    activity: f32, intensity: f32, width: f32, radius: f32, hueSpread: f32
) -> vec4f {
    let halfSize = max(size * 0.5, vec2f(1.0));
    let p = position - halfSize;
    let corner = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    let sdf = agentRoundedBox(p, halfSize - vec2f(1.0), corner);
    let inside = 1.0 - smoothstep(-0.65, 0.65, sdf);
    let distanceToEdge = max(-sdf, 0.0);
    let direction = p / halfSize;
    // All angular frequencies are integers, so the atan seam remains continuous.
    let angle = select(atan2(direction.y, direction.x), 0.0, length(direction) < 0.0001);
    let phase = angle - time * 0.38;
    let wave = 0.5 + 0.5 * sin(phase * 3.0 + 0.8 * sin(angle * 2.0 + time * 0.31));
    let swellBase = 0.5 + 0.5 * sin(phase * 2.0 - 0.65);
    let swell = swellBase * swellBase;
    let band = max(width, 1.0) * (0.38 + 0.62 * wave);
    let halo = exp(-distanceToEdge / band) * (0.15 + 0.26 * swell);
    // A broad, blurred crest rather than a sharp second outline.
    let crestDistance = distanceToEdge - band * (0.24 + 0.30 * swell);
    let crestScale = crestDistance / (band * 0.48 + 1.0);
    var crest = exp(-(crestScale * crestScale));
    crest = crest * ((0.06 + 0.13 * swell) * exp(-distanceToEdge / (band * 1.8)));
    let rim = exp(-distanceToEdge / 1.15) * (0.28 + 0.56 * swell);
    let nearRim = exp(-distanceToEdge / 5.0) * (0.07 + 0.13 * wave);
    // The center is strictly transparent, even for oversized width settings.
    let edgeMask = 1.0 - smoothstep(
        min(width * 1.9, min(halfSize.x, halfSize.y) * 0.45),
        min(width * 3.0, min(halfSize.x, halfSize.y) * 0.8),
        distanceToEdge
    );
    let hsv = agentRGBToHSV(clamp(accent, vec3f(0.0), vec3f(1.0)));
    let shift = hueSpread * sin(phase + 0.7 * sin(angle * 2.0 + time * 0.2));
    let tint = agentHSVToRGB(vec3f(fract(hsv.x + shift), hsv.y, hsv.z));
    let color = mix(tint, vec3f(1.0), clamp(rim * 0.50, 0.0, 0.45));
    var alpha = clamp((halo + crest + rim + nearRim) * intensity, 0.0, 0.94);
    alpha = alpha * inside * edgeMask * clamp(activity, 0.0, 1.0);
    return vec4f(color * alpha, alpha);
}

@fragment
fn editor_agent_activity_fragment(input: AgentGlowVertex) -> @location(0) vec4f {
    let size = material.u_Geometry.xy;
    let position = input.uv * size;
    return agentActivityGlow(
        position, size, material.u_Geometry.z, material.u_Color.rgb,
        1.0, material.u_Style.x, material.u_Geometry.w, material.u_Style.z, material.u_Style.y
    ) * material.u_Style.w;
}
