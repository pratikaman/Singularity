// Metal shaders compiled at runtime (avoids needing the Metal toolchain on beta systems).
//
// Live-screen design: instead of advecting a frozen image, we advect a FLOW FIELD —
// an rgba32f ping-pong texture where rg = the screen uv each pixel should display
// (a distortion map with full history baked in) and b = accumulated "consumed" mask.
// The display pass looks up the latest live capture frame through that field, so
// surviving regions keep playing live video while eaten regions stay eaten.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 hole;      // hole center in uv space (y down)
    float  radius;    // event horizon radius, in aspect-corrected units (screen height = 1)
    float  aspect;    // width / height
    float  dt;        // intensity-scaled frame delta
    float  time;      // sim time
    float  pull;      // radial pull strength
    float  swirl;     // angular pull strength
    float  progress;  // 0..1 over the whole meal
    float  pad;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut fsq(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Identity flow field: every pixel looks at itself, nothing consumed.
fragment float4 fieldInitFrag(VOut in [[stage_in]]) {
    return float4(in.uv, 0.0, 1.0);
}

// One simulation step on the flow field: every pixel adopts the flow line slightly
// further from the hole (content marches inward over frames), rotated around it
// (swirl). Flow lines that fall off the screen, or cross the event horizon, are
// marked consumed — so darkness pours in from the edges and trails the hole.
fragment float4 fieldFrag(VOut in [[stage_in]],
                          texture2d<float> prev [[texture(0)]],
                          constant Uniforms& U [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 p = float2(in.uv.x * U.aspect, in.uv.y);
    float2 c = float2(U.hole.x * U.aspect, U.hole.y);
    float2 d = p - c;
    float dist = length(d);
    float2 dir = d / max(dist, 1e-5);

    float r = U.radius;
    float frenzy = 1.0 + 4.0 * U.progress * U.progress * U.progress;
    float grip = (r + 0.02) * (r + 0.02);

    float pullAmt = U.dt * U.pull * frenzy * grip / (dist * dist + 0.01);
    float ang = U.dt * U.swirl * frenzy * grip / (dist * dist + (r * 0.5 + 0.01) * (r * 0.5 + 0.01));
    float ca = cos(ang), sa = sin(ang);
    float2 rd = float2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
    float2 sp = c + rd + dir * pullAmt;
    float2 suv = float2(sp.x / U.aspect, sp.y);

    float4 f = prev.sample(s, suv);
    float m = f.b;
    if (any(suv < 0.0) || any(suv > 1.0)) { m = 1.0; }   // flow line fell off the screen

    float eat = 1.0 - smoothstep(r * 0.85, r, dist);
    m = max(m, eat);
    return float4(f.rg, m, 1.0);
}

// Presentation: gravitational lensing around the hole, live capture looked up
// through the flow field, hard black horizon, accretion glow that dies out as
// the meal finishes so the end state is pure black.
fragment float4 displayFrag(VOut in [[stage_in]],
                            texture2d<float> field [[texture(0)]],
                            texture2d<float> live [[texture(1)]],
                            constant Uniforms& U [[buffer(0)]]) {
    constexpr sampler sf(filter::linear, address::clamp_to_edge);
    constexpr sampler sl(filter::linear, address::clamp_to_border, border_color::opaque_black);

    float2 p = float2(in.uv.x * U.aspect, in.uv.y);
    float2 c = float2(U.hole.x * U.aspect, U.hole.y);
    float2 d = p - c;
    float dist = length(d);
    float2 dir = d / max(dist, 1e-5);
    float r = U.radius;

    // light bending: rays near the horizon sample from further behind the hole
    float lens = (r * r * 0.85) / (dist + r * 0.35);
    float2 sp = c + dir * (dist + lens);
    float4 f = field.sample(sf, float2(sp.x / U.aspect, sp.y));

    float3 col = live.sample(sl, f.rg).rgb * (1.0 - f.b);

    // hard event horizon
    col *= smoothstep(r, r * 1.03, dist);

    // accretion glow: a hot inner ring plus a soft outer halo
    float glowFade = 1.0 - smoothstep(0.78, 0.98, U.progress);
    float halo = exp(-pow((dist - r * 1.30) / max(r * 0.40, 0.012), 2.0));
    float ring = exp(-pow((dist - r * 1.06) / max(r * 0.10, 0.005), 2.0));
    float flicker = 0.9 + 0.1 * sin(U.time * 7.0 + dist * 40.0);
    col += (float3(1.0, 0.45, 0.12) * halo * 0.35 +
            float3(1.0, 0.85, 0.55) * ring * 0.95) * glowFade * flicker;

    return float4(col, 1.0);
}
"""
