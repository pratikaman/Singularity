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
    float2 mouse;     // pointer in uv space (y down); offscreen when unused
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

// Cheap value noise + fbm for the accretion disk / halo texture.
float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i),                hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}
float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + 19.19;
        a *= 0.5;
    }
    return v;
}

// Presentation: live capture looked up through the flow field, then a
// Gargantua-style black hole drawn on top, styled after the Interstellar
// shot: a blinding thin edge-on disk crossing in FRONT of the shadow with
// wispy streaks streaming inward, the far side's light lensed into a soft
// dome over the top and a tighter arc under the bottom, a razor photon ring,
// and everything in pale cream/rose rather than lava orange, soft-clipped so
// hot cores bloom to white. Fades late so the end state is pure black.
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
    float q = dist / max(r, 1e-4);           // radius in units of the shadow
    float2 e = d / max(r, 1e-4);             // position in shadow radii (y down)
    float vert = abs(d.y) / max(dist, 1e-5); // 0 on the disk plane, 1 at the poles
    float t = U.time;

    // Interstellar palette: white-hot core, warm cream, dusty rose haze
    float3 cCore  = float3(1.00, 0.97, 0.92);
    float3 cCream = float3(1.00, 0.86, 0.74);
    float3 cRose  = float3(0.82, 0.58, 0.52);

    float3 glow = float3(0.0);

    // (1) the edge-on disk: a blinding thin plane crossing in front of the
    // shadow, its wisps streaming inward — this carries the animation
    float ax = abs(e.x);
    float nAmp = smoothstep(0.75, 1.10, q);  // wisps stay smooth where they cross the shadow
    float w1 = mix(0.5, fbm(float2(ax * 1.7 + t * 0.6, e.y * 5.0)), nAmp);
    float w2 = mix(0.5, fbm(float2(ax * 3.4 + t * 1.3, e.y * 9.0) + 31.7), nAmp);
    float thick = (0.15 + 0.11 * exp(-ax * ax * 0.2)) * (0.6 + 0.8 * w1);
    float plane = exp(-pow(e.y / max(thick, 1e-4), 2.0));
    float reach = 1.0 - smoothstep(2.3, 5.5, ax);
    float dop   = 1.0 + 0.35 * clamp(-e.x * 0.5, -0.6, 1.0);  // approaching side glares
    float disk  = plane * reach * (0.30 + 2.8 * exp(-ax * ax * 0.16))
                * (0.50 + 0.75 * w1 + 0.40 * w2) * dop;
    glow += mix(cCream, cRose, smoothstep(1.3, 4.5, ax)) * disk;
    // razor-bright centerline slicing straight across the sphere
    glow += cCore * exp(-pow(e.y / 0.05, 2.0))
          * (1.0 - smoothstep(1.6, 4.6, ax)) * dop * 1.3;

    // (2) lensed halo: far-side disk light folded into a dome over the top
    // and a tighter arc under the bottom, slowly swirling
    float ang = atan2(d.y, d.x);
    bool up = (d.y < 0.0);                   // uv is y-down
    float haloR = up ? 1.30 : 1.22;
    float haloW = 0.14 + 0.34 * vert;
    float halo  = exp(-pow((q - haloR) / haloW, 2.0))
                * smoothstep(0.90, 1.04, q)  // keep the shadow dark
                * (up ? 1.0 : 0.85) * (0.30 + 0.70 * vert);
    halo *= 0.75 + 0.5 * fbm(float2(ang * 2.0 - t * 0.4, q * 3.0));
    glow += mix(cCore, cCream, clamp((q - 1.0) * 1.4, 0.0, 1.0)) * halo * 1.6;

    // (3) photon ring: razor-thin, brilliant, right at the shadow's edge
    // (width floor keeps it from aliasing away while the hole is tiny)
    float pw = max(0.022, 0.002 / max(r, 1e-3));
    float photon = exp(-pow((q - 1.04) / pw, 2.0))
                 + 0.30 * exp(-pow((q - 1.15) / 0.05, 2.0));
    glow += cCore * photon * 2.3;

    // (4) rose-tinted bloom enveloping the whole structure; mostly kept out
    // of the shadow so the sphere reads dark with just a breath of haze
    float inShadow = 0.25 + 0.75 * smoothstep(0.85, 1.05, q);
    glow += cCream * exp(-q * q * 0.55) * 0.30 * inShadow;
    glow += cRose  * exp(-q * q * 0.10) * 0.15 * inShadow;

    // soft-clip: hot cores saturate to creamy white, tails stay soft (bloom)
    glow = 1.0 - exp(-glow * 2.1);
    col += glow * glowFade;

    // reality bubble: a small circle around the pointer always shows the live,
    // un-warped, un-eaten screen, so whatever you aim at is really there and
    // clickable; it dissolves with the finale so the end state stays black
    float2 mp = float2(U.mouse.x * U.aspect, U.mouse.y);
    float bubble = (1.0 - smoothstep(0.055, 0.085, length(p - mp)))
                 * (1.0 - smoothstep(0.90, 0.98, U.progress));
    col = mix(col, live.sample(sl, in.uv).rgb, bubble);

    return float4(col, 1.0);
}
"""
