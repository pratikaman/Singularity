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

// Presentation: live capture looked up through the flow field, then a
// Gargantua-style black hole drawn on top — pure black shadow, a razor-thin
// photon ring, a near-edge-on accretion disk whose near side crosses in FRONT
// of the shadow, the far side's light lensed into arcs over and under it,
// Doppler beaming brightening the approaching side. Everything fades late so
// the end state is pure black.
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

    // light bending of the screen content behind the hole
    float lens = (r * r * 0.85) / (dist + r * 0.35);
    float2 sp = c + dir * (dist + lens);
    float4 f = field.sample(sf, float2(sp.x / U.aspect, sp.y));
    float3 col = live.sample(sl, f.rg).rgb * (1.0 - f.b);

    // the shadow: pure black silhouette
    col *= smoothstep(r, r * 1.03, dist);

    float glowFade = 1.0 - smoothstep(0.78, 0.98, U.progress);
    float q = dist / max(r, 1e-4);          // radius in units of the shadow

    // temperature ramp: white-hot inner edge -> orange -> deep ember red
    float3 cHot = float3(1.65, 1.45, 1.25);
    float3 cMid = float3(1.55, 0.72, 0.22);
    float3 cOut = float3(0.42, 0.10, 0.03);

    // (1) near-edge-on accretion disk (y squashed hard): a thin band whose
    // near half (below center; uv is y-down) passes in front of the shadow
    float2 dpl = float2(d.x, d.y / 0.22);
    float qd = length(dpl) / max(r, 1e-4);
    float diskBand = smoothstep(1.08, 1.32, qd) * (1.0 - smoothstep(2.5, 3.4, qd));
    float phi = atan2(dpl.y, dpl.x);
    float om = 2.0 * pow(max(qd, 0.75), -1.5);        // Keplerian-ish rotation
    float streaks = 0.68 + 0.32 * sin(phi * 7.0 - U.time * om * 3.0 + qd * 5.0)
                              * sin(phi * 3.0 + U.time * om * 1.7);
    float tt = clamp((qd - 1.08) / 2.3, 0.0, 1.0);
    float3 diskCol = (tt < 0.4) ? mix(cHot, cMid, tt / 0.4)
                                : mix(cMid, cOut, (tt - 0.4) / 0.6);
    float occl = (d.y < 0.0) ? smoothstep(1.0, 1.08, q) : 1.0;   // far side hides behind shadow

    // (2) lensed image of the far side: narrow arcs hugging the shadow,
    // strongest directly above and below where the bent light folds over
    float lensRing = smoothstep(1.01, 1.05, q) * (1.0 - smoothstep(1.14, 1.30, q));
    float fold = 0.15 + 0.85 * pow(abs(d.y) / max(dist, 1e-5), 1.5);
    float3 lensCol = mix(cHot, cMid, 0.35);

    // (3) photon ring: razor-thin, brilliant, right at the shadow's edge
    float photon = exp(-pow((dist - r * 1.02) / max(r * 0.016, 0.0015), 2.0));

    // (4) Doppler beaming: the approaching (left) side burns brighter
    float dop = clamp(1.0 + 0.65 * (-d.x / max(dist, 1e-5)), 0.35, 1.75);

    float3 glow = (diskCol * diskBand * streaks * occl * 0.95
                 + lensCol * lensRing * fold * 0.5) * dop
                + float3(1.7, 1.55, 1.3) * photon * 0.85;
    col += glow * glowFade;

    // faint ambient warmth around the whole structure
    float amb = exp(-pow((q - 1.6) / 0.9, 2.0)) * 0.05;
    col += float3(1.0, 0.45, 0.15) * amb * glowFade;

    return float4(col, 1.0);
}
"""
