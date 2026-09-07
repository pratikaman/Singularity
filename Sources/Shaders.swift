// Metal shaders compiled at runtime (avoids needing the Metal toolchain on beta systems).
//
// Two simulations live here:
//
//  1. The EATING: a FLOW FIELD (rgba32f ping-pong, rg = screen uv each pixel should
//     display, b = consumed mask) advected a tiny step toward the hole every frame,
//     so live screen content genuinely streams inward and vanishes at the horizon.
//
//  2. The BLACK HOLE: a port of vgpu.sh's "optimized black hole"
//     (https://vgpu.sh/examples/optimized-black-hole, WGSL → MSL). Relativistic ray
//     traversal is BAKED once into a G-buffer (two accretion-disk crossings, the
//     lensed sky direction, hole/escape flags), REFINED with 4x4 supersampling on
//     boundary pixels, then per frame SHADED (3D-noise disk with Doppler beaming and
//     gravitational redshift), BLOOMED (3-level pyramid) and COMPOSITED (ACES).
//
//     The bake is a pure 2D similarity of the image plane, so a bake done for one
//     hole position/size is re-used for every other by remapping uvs; the app
//     re-bakes continuously in row slices (double-buffered) as the hole grows.
//     The desktop is the black hole's sky: the baked ray direction is mapped back
//     to a screen uv, so the screen content is gravitationally lensed for real.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 hole;        // hole center in uv space (y down)
    float  radius;      // apparent shadow radius, screen height = 1
    float  aspect;      // width / height
    float  dt;          // intensity-scaled frame delta
    float  time;        // sim time
    float  pull;        // radial pull strength (flow field)
    float  swirl;       // angular pull strength (flow field)
    float  progress;    // 0..1 over the whole meal
    float  glowFade;    // disk / stars fade-out near the end
    float2 mouse;       // pointer in uv space (y down); offscreen when unused
    float2 bakeHole;    // hole state the G-buffer being read/written was baked for
    float  bakeRadius;
    float  sceneYaw;    // pointer-driven disk rotation
    float2 gRes;        // G-buffer size in texels
    float  pitch;       // camera elevation above the disk plane
    float  orbit;       // camera distance (r_s = 1)
    float  roll;        // camera roll
    float  diskOuter;   // accretion disk outer radius
    float  tanPsi;      // tangent-plane radius of the shadow (b_crit at the camera)
    float  pad;
};

struct BloomU {
    float2 sourceSize;
    float2 direction;   // (0,0) downsample, else blur axis
    float4 params;      // threshold (<0 none), knee, sigma, isBlur
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

constexpr sampler linClamp(filter::linear, address::clamp_to_edge);
constexpr sampler linBlack(filter::linear, address::clamp_to_border, border_color::opaque_black);
constexpr sampler noiseSamp(filter::linear, address::repeat);

// ===================================================================== flow field

fragment float4 fieldInitFrag(VOut in [[stage_in]]) {
    return float4(in.uv, 0.0, 1.0);
}

fragment float4 fieldFrag(VOut in [[stage_in]],
                          texture2d<float> prev [[texture(0)]],
                          constant Uniforms& U [[buffer(0)]]) {
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

    float4 f = prev.sample(linClamp, suv);
    float m = f.b;
    if (any(suv < 0.0) || any(suv > 1.0)) { m = 1.0; }   // flow line fell off the screen
    return float4(f.rg, m, 1.0);
}

// ===================================================================== geodesic.wgsl

constant float HORIZON = 1.0;
constant float ISCO = 3.0;
constant int   MAX_STEPS = 768;
constant float TAU_ = 6.28318530718;
constant float PI_ = 3.14159265359;

struct TraceResult {
    float2 hit1Plane, hit1Direction, hit2Plane, hit2Direction;
    int    hitCount;
    float  swallowed, escaped;
    float3 finalVelocity;
};

struct CamRay { float3 position; float3 velocity; };
struct Basis  { float3 forward; float3 right; float3 up; };

Basis cameraBasis(float pitch) {
    float cp = clamp(pitch, -1.319, 1.319);
    float3 camPos = float3(0.0, sin(cp), cos(cp));
    Basis b;
    b.forward = -camPos;
    b.right = normalize(cross(b.forward, float3(0.0, 1.0, 0.0)));
    b.up = cross(b.right, b.forward);
    return b;
}

float escapeRadiusFor(float orbit) { return max(120.0, orbit + 8.0); }

float2 encodeDirection(float3 d) { return float2(d.y, atan2(d.z, d.x)); }

float3 geodesicAcceleration(float3 p, float3 v) {
    float r2 = max(dot(p, p), 0.0001);
    float3 L = cross(p, v);
    float h2 = dot(L, L);
    return -1.5 * h2 * p / (r2 * r2 * sqrt(r2));
}

// The G-buffer covers the screen plus a margin on every side, so the hole can
// drift between re-bakes without exposing an uncovered strip.
constant float BAKE_MARGIN = 0.08;
float2 bakeToScreen(float2 guv) { return (guv - 0.5) * (1.0 + 2.0 * BAKE_MARGIN) + 0.5; }
float2 screenToBake(float2 suv) { return (suv - 0.5) / (1.0 + 2.0 * BAKE_MARGIN) + 0.5; }

// Screen offset from the hole (in shadow radii, y up) -> camera ray. Replaces
// vgpu's fov/center parameters: the hole's on-screen size and position ARE the
// camera's zoom and pan.
CamRay cameraRay(float2 guv, constant Uniforms& U) {
    float2 suv = bakeToScreen(guv);
    float2 e = float2((suv.x - U.bakeHole.x) * U.aspect, U.bakeHole.y - suv.y) / U.bakeRadius;
    float c = cos(U.roll), s = sin(U.roll);
    float2 t = float2(e.x * c - e.y * s, e.x * s + e.y * c) * U.tanPsi;
    Basis b = cameraBasis(U.pitch);
    CamRay r;
    r.position = -b.forward * U.orbit;
    r.velocity = normalize(b.forward + b.right * t.x + b.up * t.y);
    return r;
}

TraceResult traceRay(float3 camPos, float3 v0, float diskOuter, float escapeR) {
    float3 position = camPos;
    float3 velocity = v0;
    TraceResult r;
    r.hit1Plane = 0.0; r.hit1Direction = 0.0; r.hit2Plane = 0.0; r.hit2Direction = 0.0;
    r.hitCount = 0; r.swallowed = 0.0; r.escaped = 0.0;

    for (int i = 0; i < MAX_STEPS; i++) {
        float radius = length(position);
        if (radius < HORIZON * 1.004) { r.swallowed = 1.0; break; }
        if (radius > escapeR && dot(position, velocity) > 0.0) { r.escaped = 1.0; break; }

        float stepSize = clamp((radius - HORIZON) * 0.035, 0.0045, 0.075 * max(1.0, radius / 6.0));
        float3 prevP = position, prevV = velocity;

        float3 a0 = geodesicAcceleration(position, velocity);
        velocity += a0 * (0.5 * stepSize);
        position += velocity * stepSize;
        float3 a1 = geodesicAcceleration(position, velocity);
        velocity += a1 * (0.5 * stepSize);
        velocity = normalize(velocity);

        if (r.hitCount < 2) {
            float ps = prevP.y >= 0.0 ? 1.0 : -1.0;
            float cs = position.y >= 0.0 ? 1.0 : -1.0;
            if (ps != cs) {
                float t = clamp(prevP.y / (prevP.y - position.y), 0.0, 1.0);
                float3 crossing = mix(prevP, position, t);
                float pr = length(crossing.xz);
                if (pr >= ISCO && pr <= diskOuter) {
                    float2 de = encodeDirection(normalize(mix(prevV, velocity, t)));
                    if (r.hitCount == 0) { r.hit1Plane = crossing.xz; r.hit1Direction = de; }
                    else                 { r.hit2Plane = crossing.xz; r.hit2Direction = de; }
                    r.hitCount += 1;
                }
            }
        }
    }
    r.finalVelocity = velocity;
    return r;
}

// ===================================================================== bake.wgsl

struct GBufOut {
    float2 hit1 [[color(0)]];
    float2 hit2 [[color(1)]];
    float4 sky  [[color(2)]];   // xyz = final direction, w = flags (1 hole, 2 escaped)
    float4 view [[color(3)]];   // xy = hit1 direction, zw = hit2 direction
};

fragment GBufOut bakeFrag(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
    CamRay ray = cameraRay(in.uv, U);
    TraceResult t = traceRay(ray.position, ray.velocity, U.diskOuter, escapeRadiusFor(U.orbit));
    if (t.swallowed < 0.5 && t.escaped < 0.5) { t.swallowed = 1.0; }
    GBufOut o;
    o.hit1 = t.hit1Plane;
    o.hit2 = t.hit2Plane;
    o.sky = float4(t.finalVelocity, t.swallowed * 1.0 + t.escaped * 2.0);
    o.view = float4(t.hit1Direction, t.hit2Direction);
    return o;
}

// ===================================================================== refine.wgsl

constant int   SUB_STEPS = 4;
constant int   MASK_RADIUS = 2;
constant float GRADIENT_LIMIT = 0.12;
constant float B_CRIT = 2.59807621;
constant float CRITICAL_BAND = 0.06;

bool isHitAt(float2 plane) { return length(plane) > ISCO * 0.5; }

// One thread per sub-ray (16 lanes per pixel, reduced with SIMD shuffles): the
// original fragment version looped 16 traces inside one thread, which stalls a
// whole SIMD group on every thin boundary line — fine as a one-shot, far too
// slow for a continuous re-bake.
kernel void refineKernel(texture2d<float> gHit1 [[texture(0)]],
                         texture2d<float> gSky [[texture(1)]],
                         texture2d<float, access::write> outAa [[texture(2)]],
                         texture2d<float, access::write> outGeom [[texture(3)]],
                         constant Uniforms& U [[buffer(0)]],
                         constant uint& rowOffset [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint lane [[thread_index_in_simdgroup]]) {
    uint sub = gid.x & 15u;
    int2 texel = int2(int(gid.x >> 4), int(gid.y + rowOffset));
    int2 dims = int2(U.gRes);
    if (texel.x >= dims.x || texel.y >= dims.y) { return; }
    float annulus = max(U.diskOuter - ISCO, 0.001);

    float2 centerPlane = gHit1.read(uint2(texel)).xy;
    bool centerHit = isHitAt(centerPlane);

    // lane 0 of each pixel runs the neighbourhood test, then shares the verdict
    int boundaryI = 0;
    if (sub == 0) {
        bool centerHole = (int(gSky.read(uint2(texel)).w + 0.5) & 1) != 0;
        float centerRadiusNorm = clamp((length(centerPlane) - ISCO) / annulus, 0.0, 1.0);
        CamRay centerRay = cameraRay((float2(texel) + 0.5) / U.gRes, U);
        float impact = length(cross(centerRay.position, centerRay.velocity));
        bool boundary = abs(impact - B_CRIT) < CRITICAL_BAND * HORIZON;
        for (int dy = -MASK_RADIUS; dy <= MASK_RADIUS; dy++) {
            for (int dx = -MASK_RADIUS; dx <= MASK_RADIUS; dx++) {
                int2 n = clamp(texel + int2(dx, dy), int2(0), dims - 1);
                float2 plane = gHit1.read(uint2(n)).xy;
                bool hit = isHitAt(plane);
                bool hole = (int(gSky.read(uint2(n)).w + 0.5) & 1) != 0;
                if (hit != centerHit || hole != centerHole) { boundary = true; }
                if (hit && centerHit) {
                    float rn = clamp((length(plane) - ISCO) / annulus, 0.0, 1.0);
                    if (abs(rn - centerRadiusNorm) > GRADIENT_LIMIT) { boundary = true; }
                }
            }
        }
        boundaryI = boundary ? 1 : 0;
    }
    boundaryI = simd_shuffle(boundaryI, ushort(lane & ~15u));
    if (boundaryI == 0) {
        if (sub == 0) {
            outAa.write(float4(centerHit ? 1.0 : 0.0, 0.0, 0.0, 0.0), uint2(texel));
            outGeom.write(float4(0.0), uint2(texel));
        }
        return;
    }

    float2 offset = (float2(sub & 3u, sub >> 2) + 0.5) / float(SUB_STEPS);
    float2 subUv = (float2(texel) + offset) / U.gRes;
    CamRay ray = cameraRay(subUv, U);
    TraceResult t = traceRay(ray.position, ray.velocity, U.diskOuter, escapeRadiusFor(U.orbit));
    bool hit = t.hitCount > 0;
    float radius = hit ? length(t.hit1Plane) : 0.0;
    float myDist = length(offset - 0.5);

    float hits = hit ? 1.0 : 0.0;
    float minR = hit ? radius : 1e9;
    float maxR = hit ? radius : -1e9;
    float bestDist = hit ? myDist : 1e9;
    for (ushort m = 1; m <= 8; m <<= 1) {
        hits += simd_shuffle_xor(hits, m);
        minR = min(minR, simd_shuffle_xor(minR, m));
        maxR = max(maxR, simd_shuffle_xor(maxR, m));
        bestDist = min(bestDist, simd_shuffle_xor(bestDist, m));
    }
    uint bestLane = (hit && myDist == bestDist) ? lane : 0xFFFFu;
    for (ushort m = 1; m <= 8; m <<= 1) { bestLane = min(bestLane, simd_shuffle_xor(bestLane, m)); }
    ushort src = ushort(bestLane & 31u);
    float2 bestPlane = simd_shuffle(t.hit1Plane, src);
    float2 bestDir = simd_shuffle(t.hit1Direction, src);
    float bestRadius = simd_shuffle(radius, src);
    if (sub != 0) { return; }

    if (hits < 0.5) {
        outAa.write(float4(0.0), uint2(texel));
        outGeom.write(float4(0.0), uint2(texel));
        return;
    }
    float coverage = hits / float(SUB_STEPS * SUB_STEPS);
    float r0 = length(centerPlane);
    float span = 0.0;
    float4 geometry = 0.0;
    if (centerHit) {
        span = 2.0 * max(abs(maxR - r0), abs(r0 - minR));
    } else {
        r0 = 0.5 * (minR + maxR);
        span = maxR - minR;
        geometry = float4(bestPlane * (r0 / max(bestRadius, ISCO)), bestDir);
    }
    outAa.write(float4(coverage, clamp(span / annulus, 0.0, 1.0), 0.0, 0.0), uint2(texel));
    outGeom.write(geometry, uint2(texel));
}

// ===================================================================== gbuffer.wgsl

struct GBufferSample {
    float3 position, normal;
    float2 diskUv, diskPolar;
    float3 rayDirection, viewDirection;
    float  side, coverage, span;
    bool   isHit, synthesized, isBlackHole, escaped;
};
struct GBufferLayers { GBufferSample front; GBufferSample back; };

float3 decodeDirection(float2 e) {
    float h = sqrt(max(1.0 - e.x * e.x, 0.0));
    return float3(cos(e.y) * h, e.x, sin(e.y) * h);
}

GBufferSample decodeLayer(float2 plane, float2 encDir, float4 sky, int flags,
                          float diskOuter, float2 aa, bool synthesized) {
    GBufferSample s;
    float planeRadius = length(plane);
    bool isHit = planeRadius > ISCO * 0.5;
    float radius = max(planeRadius, ISCO);
    float azimuth = atan2(plane.y, plane.x);
    float3 direction = decodeDirection(encDir);
    float side = direction.y > 0.0 ? -1.0 : 1.0;

    s.position = isHit ? float3(plane.x, 0.0, plane.y) : float3(0.0);
    s.normal = isHit ? float3(0.0, side, 0.0) : float3(0.0);
    s.diskUv = float2(clamp((radius - ISCO) / max(diskOuter - ISCO, 0.001), 0.0, 1.0),
                      (azimuth + PI_) / TAU_);
    s.diskPolar = float2(radius, azimuth);
    s.rayDirection = sky.xyz;
    s.viewDirection = direction;
    s.side = isHit ? side : 0.0;
    s.coverage = clamp(aa.x, 0.0, 1.0);
    s.span = clamp(aa.y, 0.0, 1.0);
    s.isHit = isHit;
    s.synthesized = synthesized && isHit;
    s.isBlackHole = (flags & 1) != 0;
    s.escaped = (flags & 2) != 0;
    return s;
}

GBufferLayers decodeGBuffer(float2 hit1, float2 hit2, float4 sky, float4 view,
                            float diskOuter, float2 aa, float4 aaGeom) {
    int flags = int(sky.w + 0.5);
    bool substitute = length(hit1) <= ISCO * 0.5 && length(aaGeom.xy) > ISCO * 0.5;
    float2 frontPlane = substitute ? aaGeom.xy : hit1;
    float2 frontDir = substitute ? aaGeom.zw : view.xy;
    GBufferLayers L;
    L.front = decodeLayer(frontPlane, frontDir, sky, flags, diskOuter, aa, substitute);
    L.back = decodeLayer(hit2, view.zw, sky, flags, diskOuter, float2(1.0, 0.0), false);
    if (!L.front.isHit) {
        L.back.isHit = false;
        L.back.side = 0.0;
        L.back.normal = 0.0;
    }
    return L;
}

GBufferSample sampleAtRadius(GBufferSample g, float radius, float diskOuter) {
    GBufferSample m = g;
    float c = clamp(radius, ISCO, max(diskOuter, ISCO));
    float az = g.diskPolar.y;
    m.position = float3(cos(az) * c, 0.0, sin(az) * c);
    m.diskPolar = float2(c, az);
    m.diskUv = float2(clamp((c - ISCO) / max(diskOuter - ISCO, 0.001), 0.0, 1.0), g.diskUv.y);
    return m;
}

// ===================================================================== disk.wgsl

struct DiskLook {
    float brightness, speed, stretch, detail, turbulence, density, doppler;
    float cloudScale, cloudSpeed, cloudStrength;
    float spare0, spare1, spare2, spare3;
};
struct DiskSample { float3 color; float alpha; };

// vgpu's production defaults (settings.ts).
DiskLook diskLook() {
    DiskLook l;
    l.brightness = 0.75; l.speed = 0.75; l.stretch = 5.75; l.detail = 3.44;
    l.turbulence = 4.46; l.density = 1.38; l.doppler = 1.21;
    l.cloudScale = 20.0; l.cloudSpeed = 0.3; l.cloudStrength = 0.2;
    l.spare0 = 0.43; l.spare1 = -0.25; l.spare2 = -0.67; l.spare3 = 0.69;
    return l;
}

float noise3(texture3d<float> tex, float invSize, float3 p) {
    float3 i = floor(p);
    float3 f = p - i;
    float3 u = f * f * (3.0 - 2.0 * f);
    return tex.sample(noiseSamp, (i + u + 0.5) * invSize, level(0.0)).r;
}

float streakFbm(texture3d<float> tex, float invSize, float angle, float radius,
                float angScale, float radScale, int octaves, float dAngle, float dRadius,
                float lacAng, float lacRad, float seed) {
    float value = 0.0, total = 0.0, amplitude = 0.5;
    float a = angScale, r = radScale, offset = seed;
    for (int i = 0; i < octaves; i++) {
        float visible = clamp(1.0 - 1.7 * max(dAngle * a, dRadius * r), 0.0, 1.0);
        float sv = 0.5;
        if (visible > 0.004) {
            sv = mix(0.5, noise3(tex, invSize, float3(cos(angle) * a, sin(angle) * a, radius * r + offset)), visible);
        }
        value += amplitude * sv;
        total += amplitude;
        a *= lacAng; r *= lacRad; offset += 23.7; amplitude *= 0.55;
    }
    return value / max(total, 0.0001);
}

float ridgeFbm(texture3d<float> tex, float invSize, float angle, float radius,
               float angScale, float radScale, int octaves, float dAngle, float dRadius,
               float lacAng, float lacRad, float seed) {
    float value = 0.0, total = 0.0, amplitude = 0.5;
    float a = angScale, r = radScale, offset = seed;
    for (int i = 0; i < octaves; i++) {
        float visible = clamp(1.0 - 1.7 * max(dAngle * a, dRadius * r), 0.0, 1.0);
        float crest = 0.42;
        if (visible > 0.004) {
            float n = noise3(tex, invSize, float3(cos(angle) * a, sin(angle) * a, radius * r + offset));
            crest = mix(0.42, pow(1.0 - abs(n * 2.0 - 1.0), 1.35), visible);
        }
        value += amplitude * crest;
        total += amplitude;
        a *= lacAng; r *= lacRad; offset += 41.9; amplitude *= 0.62;
    }
    return value / max(total, 0.0001);
}

struct FieldParams { float angBase, radBase, flowRad, chaos, outward, dAngle, dRadius; };

float2 smokeField(texture3d<float> tex, float invSize, float angle, float radius, FieldParams p) {
    float warpA = streakFbm(tex, invSize, angle, radius, p.angBase * 0.55, p.flowRad * 1.6,
                            2, p.dAngle, p.dRadius, 1.6, 2.0, 3.7) - 0.5;
    float warpB = streakFbm(tex, invSize, angle + 2.4, radius * 1.13, p.angBase * 2.8, p.radBase * 0.45,
                            3, p.dAngle, p.dRadius, 1.7, 2.0, 61.3) - 0.5;
    float radiusW = radius + (warpA * 1.9 + warpB * 1.25 * p.outward) * p.chaos;
    float angleW = angle + (warpB * 0.9 - warpA * 0.35) * p.chaos * 0.55 / max(radius * 0.22, 0.35);

    float flow = streakFbm(tex, invSize, angleW, radiusW, p.angBase, p.flowRad,
                           3, p.dAngle, p.dRadius, 2.0, 1.12, 131.7);
    float threads = ridgeFbm(tex, invSize, angleW, radiusW, p.angBase * 0.85, p.radBase,
                             5, p.dAngle, p.dRadius, 1.26, 2.05, 0.0);

    float fineVis = clamp(1.0 - 1.7 * max(p.dAngle * p.angBase * 0.85, p.dRadius * p.radBase), 0.0, 1.0);
    float field = mix(flow, flow * 0.22 + threads * 1.05, fineVis);
    float rim = (warpA + warpB * 0.5) * 0.9;
    return float2(field, rim);
}

constant float FIELD_MEAN = 0.52;
constant float SHEAR_REF_RADIUS = 6.5;
constant float SHEAR_PERIOD = 10.0;

DiskSample shadeDisk(GBufferSample g, DiskLook look, float time, float footprint, texture3d<float> noiseTex) {
    float invSize = 1.0 / float(noiseTex.get_width());

    float2 plane = float2(g.position.x, g.position.z);
    float radius = g.diskPolar.x;
    float azimuth = g.diskPolar.y;
    float radiusNorm = clamp(g.diskUv.x, 0.0, 1.0);
    float3 viewDirection = g.viewDirection;

    float slant = max(abs(viewDirection.y), 0.022);
    float grazing = min(1.0 / slant, 34.0);

    float2 viewPlane = normalize(float2(viewDirection.x, viewDirection.z) + float2(1e-6, 0.0));
    float2 radialDir = normalize(plane + float2(1e-6, 0.0));
    float alignR = clamp(abs(dot(radialDir, viewPlane)), 0.0, 1.0);
    float alignT = sqrt(max(1.0 - alignR * alignR, 0.0));
    float stretchSq = grazing * grazing - 1.0;
    float kR = sqrt(1.0 + stretchSq * alignR * alignR);
    float kT = sqrt(1.0 + stretchSq * alignT * alignT);
    float baseScaleR = max(look.detail, 0.05);
    float baseScaleA = max(look.stretch, 0.05);
    float pixelWorld = footprint / max(baseScaleR * kR, baseScaleA * kT / max(radius, ISCO));
    float dRadius = pixelWorld * kR;
    float dAngle = pixelWorld * kT / max(radius, ISCO);

    float omega = look.speed * 0.55 / pow(radius, 1.5);
    float omegaRef = look.speed * 0.55 / pow(SHEAR_REF_RADIUS, 1.5);
    float dOmega = omega - omegaRef;
    float rigid = fract(time * omegaRef / TAU_) * TAU_;
    float swirl = max(0.0, 0.85 + look.spare1);
    float flowBase = azimuth - rigid + swirl * log(radius / ISCO);

    float cycle = time / SHEAR_PERIOD;
    float u0 = fract(cycle);
    float u1 = fract(cycle + 0.5);
    float shear0 = (u0 - 0.5) * SHEAR_PERIOD;
    float shear1 = (u1 - 0.5) * SHEAR_PERIOD;
    float w0 = 1.0 - abs(2.0 * u0 - 1.0);
    float w1 = 1.0 - w0;
    float angle0 = flowBase - dOmega * shear0;
    float angle1 = flowBase - dOmega * shear1;

    float outward = smoothstep(0.0, 0.92, radiusNorm);
    float fray = max(0.0, 1.0 + look.spare3);
    float chaos = look.turbulence * (0.08 + 2.10 * outward * outward) * fray;

    float angBase = max(look.stretch, 0.05) * 0.45 * (0.80 + 1.45 * outward * fray);
    float radBase = max(look.detail, 0.05) * 2.35;
    float flowRad = max(look.detail, 0.05) * 0.105;

    FieldParams params;
    params.angBase = angBase; params.radBase = radBase; params.flowRad = flowRad;
    params.chaos = chaos; params.outward = outward; params.dAngle = dAngle; params.dRadius = dRadius;
    float lobeShift = abs(dOmega) * SHEAR_PERIOD * 0.5 * angBase * 0.85;
    float rho = 1.0 - smoothstep(0.12, 1.1, lobeShift);

    float2 blended;
    float lobeVariance = 1.0;
    if (rho > 0.98) {
        float angleMerged = mix(angle1, angle0, w0);
        blended = smokeField(noiseTex, invSize, angleMerged, radius, params);
    } else {
        float2 lobe0 = smokeField(noiseTex, invSize, angle0, radius, params);
        float2 lobe1 = smokeField(noiseTex, invSize, angle1, radius, params);
        blended = mix(lobe1, lobe0, w0);
        lobeVariance = sqrt(max(w0 * w0 + w1 * w1 + 2.0 * rho * w0 * w1, 0.25));
    }
    float field = FIELD_MEAN + (blended.x - FIELD_MEAN) / lobeVariance;

    float cloudRate = omegaRef * look.cloudSpeed;
    float cloudRigid = fract(time * cloudRate / TAU_) * TAU_;
    float cloudAngle = azimuth - cloudRigid + 0.32 * log(radius / ISCO);
    float cloudScale = max(look.cloudScale, 0.05);
    float cloudRaw = streakFbm(noiseTex, invSize, cloudAngle, radius, cloudScale, cloudScale * 0.34,
                               2, dAngle, dRadius, 1.72, 1.86, 211.7);
    float cloud = smoothstep(0.28, 0.72, cloudRaw);
    float cloudStrength = clamp(look.cloudStrength, 0.0, 0.95);
    float cloudMultiplier = mix(1.0 - cloudStrength, 1.0 + cloudStrength, cloud);
    field *= cloudMultiplier;

    float rimNoise = blended.y;
    float innerEdge = smoothstep(0.0, 0.055, radiusNorm);
    float outerEdge = 1.0 - smoothstep(0.42 + rimNoise * 0.30 * fray, 1.0, radiusNorm);
    float envelope = innerEdge * outerEdge * mix(1.0, 0.62, outward);

    float contrast = max(0.2, 1.0 + look.spare2);
    float lo = 0.50 - 0.16 / contrast;
    float hi = 0.50 + 0.21 / contrast;
    float smoke = clamp(pow(smoothstep(lo, hi, field), 1.0 + 0.9 * contrast) * envelope, 0.0, 1.0);

    float fieldN = clamp((field - (lo - 0.10)) / max(hi - lo + 0.26, 0.02), 0.0, 1.0);
    float emissivity = (mix(0.05, 1.0, pow(fieldN, 1.35)) + 2.2 * pow(fieldN, 5.0)) * envelope;

    float path = pow(grazing, 0.62);
    float thickness = mix(0.30, 0.85, radiusNorm);
    float opticalDepth = smoke * thickness * path * look.density * 0.95;
    float coverage = 1.0 - exp(-opticalDepth);

    float heat = pow(1.0 - radiusNorm, 1.25);
    float3 thermal = mix(float3(0.52, 0.14, 0.03), float3(1.0, 0.56, 0.17), smoothstep(0.03, 0.5, heat));
    thermal = mix(thermal, float3(1.0, 0.94, 0.83), pow(heat, 2.2));

    float3 tangent = normalize(float3(-plane.y, 0.0, plane.x));
    float orbitalSpeed = min(0.64, 0.94 / sqrt(max(radius - HORIZON, 0.25)));
    float towardObserver = dot(tangent, -normalize(viewDirection));
    float beaming = pow(clamp(1.0 / (1.0 - orbitalSpeed * towardObserver), 0.72, 1.55), 1.5 * look.doppler);
    float redshift = sqrt(max(1.0 - HORIZON / radius, 0.025));

    float facing = mix(0.82, 1.0, step(0.0, g.side));

    float flux = pow(clamp(ISCO / radius, 0.0, 1.0), 1.7);
    float core = 1.0 + 2.6 * pow(1.0 - radiusNorm, 5.0);

    float arcLift = max(0.0, 1.0 + look.spare0);
    float faceOn = smoothstep(0.16, 0.75, abs(viewDirection.y));
    float lift = 1.0 + 1.55 * arcLift * faceOn;
    float edgeGlow = 1.0 + 0.55 * smoothstep(6.0, 26.0, grazing);

    float3 source = thermal * beaming * redshift * facing * flux * lift * edgeGlow * core * emissivity;
    DiskSample s;
    s.color = source * look.brightness * 1.35;
    s.alpha = coverage;
    return s;
}

// ===================================================================== stars.wgsl

struct StarLook { float brightness, density, contrast, warmth, twinkle; };
StarLook starLook() {
    StarLook l;
    l.brightness = 1.0; l.density = 1.0; l.contrast = 13.0; l.warmth = 0.5; l.twinkle = 0.0;
    return l;
}

constant float STAR_INTENSITY = 1.9;
constant float ANCHOR_CELLS = 36.0, ANCHOR_FILL = 0.75, ANCHOR_RADIUS = 0.00110, ANCHOR_PEAK = 1.0;
constant float FIELD_CELLS = 93.0, FIELD_FILL = 0.75, FIELD_RADIUS = 0.00070, FIELD_PEAK = 0.45;
constant float DUST_CELLS = 151.0, DUST_FILL = 0.75, DUST_RADIUS = 0.00040, DUST_PEAK = 0.22;
constant float COUNT_SLOPE = 2.0;
constant float STAR_FLUX_AREA = 0.5385;
constant float MAX_PREFILTER_PIXELS = 4.0;
constant float3 STAR_WARM = float3(1.1741, 0.9745, 0.7397);
constant float3 STAR_COOL = float3(0.8954, 1.0131, 1.1781);

uint3 pcg3d(uint3 v) {
    uint3 h = v * 1664525u + 1013904223u;
    h.x = h.x + h.y * h.z; h.y = h.y + h.z * h.x; h.z = h.z + h.x * h.y;
    h = h ^ (h >> 16u);
    h.x = h.x + h.y * h.z; h.y = h.y + h.z * h.x; h.z = h.z + h.x * h.y;
    h = h ^ (h >> 16u);
    return h;
}
float unitFloat(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }

float3 faceCoords(float3 d) {
    float3 m = abs(d);
    if (m.x >= m.y && m.x >= m.z) { return float3(d.yz / m.x, d.x > 0.0 ? 0.0 : 1.0); }
    if (m.y >= m.z)               { return float3(d.xz / m.y, d.y > 0.0 ? 2.0 : 3.0); }
    return float3(d.xy / m.z, d.z > 0.0 ? 4.0 : 5.0);
}
float2 faceProject(float3 d, int axis) {
    if (axis == 0) { return d.yz / abs(d.x); }
    if (axis == 1) { return d.xz / abs(d.y); }
    return d.xy / abs(d.z);
}

struct SkyFilter { float2x2 inverseJacobian; float pixelsPerFace; float faceMajor; };

SkyFilter skyFilter(float3 d, int axis, float3 ddx, float3 ddy) {
    float2 base = faceProject(d, axis);
    float2 jx = faceProject(d + ddx, axis) - base;
    float2 jy = faceProject(d + ddy, axis) - base;
    float det = jx.x * jy.y - jx.y * jy.x;
    float safeDet = abs(det) < 1.0e-24 ? 1.0e-24 : det;
    SkyFilter f;
    f.inverseJacobian = float2x2(float2(jy.y, -jx.y), float2(-jy.x, jx.x)) * (1.0 / safeDet);
    f.pixelsPerFace = 1.0 / sqrt(max(abs(det), 1.0e-24));
    f.faceMajor = max(length(jx), length(jy));
    return f;
}

struct SkyState { float brightness, rangePower, meanFlux, warmth, twinkle, time, fillScale, radiusScale; };

SkyState resolveSky(StarLook look, float2 face, float time) {
    float range = clamp(look.contrast, 1.0, 512.0);
    float compression = 1.0 + dot(face, face);
    float root = sqrt(compression);
    SkyState s;
    s.brightness = max(0.0, look.brightness) * STAR_INTENSITY;
    s.rangePower = range * range;
    s.meanFlux = COUNT_SLOPE / (range + COUNT_SLOPE - 1.0);
    s.warmth = clamp(look.warmth, 0.0, 1.0);
    s.twinkle = clamp(look.twinkle, 0.0, 1.0);
    s.time = time;
    s.fillScale = max(0.0, look.density) / (compression * root);
    s.radiusScale = sqrt(compression * root);
    return s;
}

struct Species { float cells, fill, peak, faceRadius, radiusPixels, gain; };

Species resolveSpecies(float cells, float fill, float peak, float angularRadius, SkyState sky, SkyFilter pf) {
    float faceRadius = angularRadius * sky.radiusScale;
    float starPixels = faceRadius * pf.pixelsPerFace;
    Species s;
    s.cells = cells;
    s.fill = clamp(fill * sky.fillScale, 0.0, 1.0);
    s.peak = peak * sky.brightness;
    s.faceRadius = faceRadius;
    s.radiusPixels = clamp(starPixels, 1.0, MAX_PREFILTER_PIXELS);
    s.gain = min(1.0, starPixels * starPixels);
    return s;
}

float3 starPoint(float2 cell, float2 grid, int faceIndex, int seed, Species sp, SkyState sky, SkyFilter pf) {
    uint3 hashed = pcg3d(as_type<uint3>(int3(int2(cell), faceIndex * 131 + seed)));
    float presence = unitFloat(hashed.x);
    if (presence > sp.fill) { return float3(0.0); }
    float2 jitter = float2(unitFloat(hashed.y), unitFloat(hashed.z)) - 0.5;
    float2 center = cell + 0.5 + jitter * 0.8;
    float2 offsetPixels = pf.inverseJacobian * ((grid - center) / sp.cells);
    float falloff = 1.0 - smoothstep(0.0, sp.radiusPixels, length(offsetPixels));
    float uniform01 = presence / max(sp.fill, 1.0e-6);
    float flux = rsqrt(1.0 + uniform01 * (sky.rangePower - 1.0));
    float3 tint = mix(float3(1.0), mix(STAR_WARM, STAR_COOL, unitFloat(hashed.y ^ hashed.z)), sky.warmth);
    float phase = unitFloat(hashed.y) * 6.2831853;
    float shimmer = 1.0 + sky.twinkle * 0.06 * sin(sky.time * (0.35 + unitFloat(hashed.z) * 0.4) + phase);
    return tint * (falloff * falloff * sp.peak * flux * shimmer * sp.gain);
}

float3 starSpecies(float3 face, int seed, Species sp, SkyState sky, SkyFilter pf) {
    int faceIndex = int(face.z);
    float2 grid = face.xy * sp.cells;
    float3 total = starPoint(floor(grid), grid, faceIndex, seed, sp, sky, pf);
    float extent = sp.faceRadius * sp.cells;
    float mean = sp.peak * sky.meanFlux * sp.fill * STAR_FLUX_AREA * extent * extent;
    float3 meanTint = mix(float3(1.0), 0.5 * (STAR_WARM + STAR_COOL), sky.warmth);
    float cellsPerPixel = sp.cells * pf.faceMajor;
    return mix(total, meanTint * mean, smoothstep(1.0, 3.0, cellsPerPixel));
}

float3 shadeStars(float3 direction, StarLook look, float time, float3 ddx, float3 ddy) {
    float3 d = normalize(direction);
    float3 face = faceCoords(d);
    SkyFilter pf = skyFilter(d, int(face.z) / 2, ddx, ddy);
    SkyState sky = resolveSky(look, face.xy, time);
    return starSpecies(face, 17, resolveSpecies(ANCHOR_CELLS, ANCHOR_FILL, ANCHOR_PEAK, ANCHOR_RADIUS, sky, pf), sky, pf)
         + starSpecies(face, 71, resolveSpecies(FIELD_CELLS, FIELD_FILL, FIELD_PEAK, FIELD_RADIUS, sky, pf), sky, pf)
         + starSpecies(face, 149, resolveSpecies(DUST_CELLS, DUST_FILL, DUST_PEAK, DUST_RADIUS, sky, pf), sky, pf);
}

// ===================================================================== shade.wgsl

constant float DISK_GAIN = 1.35;
constant int   AA_TAPS = 6;
constant float AA_SPAN_MIN = 0.15;

float2 diskFootprintAxes(GBufferSample g, DiskLook disk, float time) {
    float angular = max(disk.stretch, 0.05);
    float noiseAngle = g.diskPolar.y - min(time, SHEAR_PERIOD * 0.5) * (disk.speed * 0.55 / pow(g.diskPolar.x, 1.5));
    float3 nc = float3(cos(noiseAngle) * angular, sin(noiseAngle) * angular, g.diskPolar.x * disk.detail);
    return float2(max(fwidth(nc.x), fwidth(nc.y)), fwidth(nc.z));
}
float diskFootprint(float2 axes) { return min(max(axes.x, axes.y), 4.0); }

float3 rotateY(float3 v, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}
float wrapAngle(float a) { return a - TAU_ * floor((a + PI_) / TAU_); }

GBufferSample rotateSample(GBufferSample g, float angle) {
    GBufferSample r = g;
    r.position = rotateY(g.position, angle);
    r.viewDirection = rotateY(g.viewDirection, angle);
    r.rayDirection = rotateY(g.rayDirection, angle);
    float az = wrapAngle(g.diskPolar.y - angle);
    r.diskPolar = float2(g.diskPolar.x, az);
    r.diskUv = float2(g.diskUv.x, (az + PI_) / TAU_);
    return r;
}

DiskSample shadeFront(GBufferSample g, DiskLook disk, float time, float diskOuter,
                      float footprint, float angularFootprint, texture3d<float> noiseTex) {
    float annulus = max(diskOuter - ISCO, 0.001);
    float spanWorld = g.span * annulus;
    if (g.span <= AA_SPAN_MIN) { return shadeDisk(g, disk, time, footprint, noiseTex); }

    float tapFootprint = min(max(angularFootprint, max(disk.detail, 0.05) * (spanWorld / float(AA_TAPS))), 4.0);
    float step_ = spanWorld / float(AA_TAPS);
    float start = g.diskPolar.x - spanWorld * 0.5;

    float3 sumEmission = 0.0;
    float sumAlpha = 0.0, taps = 0.0;
    for (int i = 0; i < AA_TAPS; i++) {
        float radius = start + (float(i) + 0.5) * step_;
        if (radius < ISCO || radius > diskOuter) { continue; }
        DiskSample tap = shadeDisk(sampleAtRadius(g, radius, diskOuter), disk, time, tapFootprint, noiseTex);
        sumEmission += tap.color * tap.alpha;
        sumAlpha += tap.alpha;
        taps += 1.0;
    }
    if (taps < 0.5) { return shadeDisk(g, disk, time, footprint, noiseTex); }

    DiskSample s;
    float meanAlpha = sumAlpha / taps;
    s.alpha = meanAlpha;
    s.color = meanAlpha > 1e-6 ? (sumEmission / taps) / max(meanAlpha, 1e-6) : float3(0.0);
    return s;
}

float3 compositeDisk(float3 under, DiskSample s) {
    return s.color * s.alpha * DISK_GAIN + under * (1.0 - s.alpha);
}

// Output: premultiplied disk emission (rgb) + total opacity (a): 1 inside the
// shadow, disk coverage elsewhere. Background is composited in the display pass.
fragment float4 shadeFrag(VOut in [[stage_in]],
                          texture2d<float> gHit1 [[texture(0)]],
                          texture2d<float> gHit2 [[texture(1)]],
                          texture2d<float> gSky [[texture(2)]],
                          texture2d<float> gView [[texture(3)]],
                          texture2d<float> gAa [[texture(4)]],
                          texture2d<float> gAaGeom [[texture(5)]],
                          texture3d<float> noiseTex [[texture(6)]],
                          constant Uniforms& U [[buffer(0)]]) {
    float2 dims = U.gRes;
    uint2 texel = uint2(clamp(in.uv * dims, float2(0.0), dims - 1.0));
    DiskLook disk = diskLook();

    float2 aa = gAa.read(texel).xy;
    float4 aaGeom = gAaGeom.read(texel);
    GBufferLayers baked = decodeGBuffer(gHit1.read(texel).xy, gHit2.read(texel).xy,
                                       gSky.read(texel), gView.read(texel),
                                       U.diskOuter, aa, aaGeom);

    if (U.glowFade <= 0.0) {   // finale: only the shadow is left
        return float4(0.0, 0.0, 0.0, baked.front.isBlackHole ? 1.0 : 0.0);
    }

    float2 frontAxes = diskFootprintAxes(baked.front, disk, U.time);
    float2 backAxes = diskFootprintAxes(baked.back, disk, U.time);
    float frontFootprint = diskFootprint(frontAxes);
    float backFootprint = diskFootprint(backAxes);

    GBufferLayers layers;
    layers.front = rotateSample(baked.front, -U.sceneYaw);
    layers.back = rotateSample(baked.back, -U.sceneYaw);

    DiskSample backSample; backSample.color = 0.0; backSample.alpha = 0.0;
    DiskSample frontSample; frontSample.color = 0.0; frontSample.alpha = 0.0;
    if (layers.back.isHit) {
        backSample = shadeDisk(layers.back, disk, U.time, backFootprint, noiseTex);
    }
    if (layers.front.isHit) {
        frontSample = shadeFront(layers.front, disk, U.time, U.diskOuter, frontFootprint, frontAxes.x, noiseTex);
        frontSample.alpha *= layers.front.coverage;
    }
    backSample.alpha *= U.glowFade;
    frontSample.alpha *= U.glowFade;

    float3 color = 0.0;
    color = compositeDisk(color, backSample);
    color = compositeDisk(color, frontSample);
    float bgWeight = (1.0 - frontSample.alpha) * (1.0 - backSample.alpha);
    if (baked.front.isBlackHole) { bgWeight = 0.0; }
    return float4(color, 1.0 - bgWeight);
}

// ===================================================================== bloom.wgsl

float3 softThreshold(float3 color, constant BloomU& B) {
    float threshold = B.params.x;
    if (threshold <= 0.0) { return color; }
    float brightness = dot(color, float3(0.2126, 0.7152, 0.0722));
    float knee = max(min(B.params.y, threshold), 0.000001);
    float soft = clamp(brightness - threshold + knee, 0.0, 2.0 * knee);
    float softContribution = soft * soft / (4.0 * knee + 0.0001);
    float contribution = max(brightness - threshold, softContribution) / max(brightness, 0.0001);
    return color * contribution;
}

fragment float4 bloomFrag(VOut in [[stage_in]],
                          texture2d<float> source [[texture(0)]],
                          constant BloomU& B [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 color;
    if (B.params.w > 0.5) {
        float sigma = max(B.params.z, 0.5);
        float k = 0.5 / (sigma * sigma);
        float w0 = 1.0;
        float w1 = exp(-1.0 * k), w2 = exp(-4.0 * k), w3 = exp(-9.0 * k), w4 = exp(-16.0 * k);
        float pair12 = w1 + w2, pair34 = w3 + w4;
        float offset12 = (w1 + 2.0 * w2) / max(pair12, 0.000001);
        float offset34 = (3.0 * w3 + 4.0 * w4) / max(pair34, 0.000001);
        float norm = w0 + 2.0 * (pair12 + pair34);
        float2 texel = B.direction / B.sourceSize;
        color = source.sample(linClamp, uv).rgb * w0;
        color += source.sample(linClamp, uv + texel * offset12).rgb * pair12;
        color += source.sample(linClamp, uv - texel * offset12).rgb * pair12;
        color += source.sample(linClamp, uv + texel * offset34).rgb * pair34;
        color += source.sample(linClamp, uv - texel * offset34).rgb * pair34;
        color /= norm;
    } else {
        float2 o = 0.5 / B.sourceSize;
        color = (source.sample(linClamp, uv + float2(-o.x, -o.y)).rgb +
                 source.sample(linClamp, uv + float2( o.x, -o.y)).rgb +
                 source.sample(linClamp, uv + float2(-o.x,  o.y)).rgb +
                 source.sample(linClamp, uv + float2( o.x,  o.y)).rgb) * 0.25;
        color = softThreshold(color, B);
    }
    return float4(color, 1.0);
}

// ===================================================================== composite.wgsl

constant float EXPOSURE = 1.15;
constant float SATURATION = 0.0;   // vgpu's monochrome Interstellar look; 1.0 = full color
constant float BLOOM_STRENGTH = 1.0;

float3 aces(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
float3 tonemap(float3 linearColor) {
    float3 c = aces(linearColor * EXPOSURE);
    c = pow(c, 1.0 / 2.2);
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    return mix(float3(luma), c, SATURATION);
}

fragment float4 compositeFrag(VOut in [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloomNear [[texture(1)]],
                              texture2d<float> bloomMedium [[texture(2)]],
                              texture2d<float> bloomFar [[texture(3)]]) {
    float4 s = scene.sample(linClamp, in.uv);
    float3 bloom = bloomNear.sample(linClamp, in.uv).rgb * 0.50
                 + bloomMedium.sample(linClamp, in.uv).rgb * 0.32
                 + bloomFar.sample(linClamp, in.uv).rgb * 0.18;
    return float4(tonemap(s.rgb + bloom * BLOOM_STRENGTH), s.a);
}

// ===================================================================== display

// Undeflected camera direction of a screen pixel under the CURRENT hole state
// (fallback for pixels whose sky direction is unavailable).
float3 pixelDirection(float2 uv, constant Uniforms& U) {
    float2 e = float2((uv.x - U.hole.x) * U.aspect, U.hole.y - uv.y) / U.radius;
    float c = cos(U.roll), s = sin(U.roll);
    float2 t = float2(e.x * c - e.y * s, e.x * s + e.y * c) * U.tanPsi;
    Basis b = cameraBasis(U.pitch);
    return normalize(b.forward + b.right * t.x + b.up * t.y);
}

fragment float4 displayFrag(VOut in [[stage_in]],
                            texture2d<float> field [[texture(0)]],
                            texture2d<float> live [[texture(1)]],
                            texture2d<float> layer [[texture(2)]],
                            texture2d<float> gSky [[texture(3)]],
                            constant Uniforms& U [[buffer(0)]]) {
    float2 uv = in.uv;
    // screen -> bake space: the bake is a similarity of the image plane
    float2 guv = screenToBake(U.bakeHole + (uv - U.hole) * (U.bakeRadius / U.radius));

    // lensed sky direction: bilinear over the escaped texels only, so the
    // shadow edge / photon ring don't bleed garbage directions
    float2 gp = guv * U.gRes - 0.5;
    float2 gi = floor(gp);
    float2 gf = gp - gi;
    float3 dirSum = 0.0;
    float wsum = 0.0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            float2 cp = clamp(gi + float2(i, j), float2(0.0), U.gRes - 1.0);
            float4 s = gSky.read(uint2(cp));
            float w = (i == 1 ? gf.x : 1.0 - gf.x) * (j == 1 ? gf.y : 1.0 - gf.y);
            w *= ((int(s.w + 0.5) & 2) != 0) ? 1.0 : 0.0;
            dirSum += s.xyz * w;
            wsum += w;
        }
    }
    bool escaped = wsum > 0.0;
    float3 d = escaped ? normalize(dirSum) : pixelDirection(uv, U);
    float3 ddx = dfdx(d);
    float3 ddy = dfdy(d);

    // direction -> screen uv (the desktop is the sky at infinity)
    Basis b = cameraBasis(U.pitch);
    float tf = dot(d, b.forward);
    float2 t = float2(dot(d, b.right), dot(d, b.up)) / max(tf, 1e-3);
    float2 ep = t / U.tanPsi;
    float c = cos(U.roll), s = sin(U.roll);
    float2 e = float2(ep.x * c + ep.y * s, -ep.x * s + ep.y * c);
    float2 luv = U.hole + float2(e.x / U.aspect, -e.y) * U.radius;

    float4 f = field.sample(linClamp, luv);
    float consumed = f.b;
    if (any(luv < 0.0) || any(luv > 1.0) || tf < 1e-3) { consumed = 1.0; }
    float3 content = live.sample(linBlack, f.rg).rgb;
    float3 bg = content * (1.0 - consumed);
    if (consumed > 0.001) {
        float3 stars = tonemap(shadeStars(d, starLook(), U.time, ddx, ddy));
        bg += stars * consumed * U.glowFade;
    }

    float4 L = layer.sample(linClamp, guv);
    float3 col = bg * (1.0 - L.a) + L.rgb;

    // reality bubble: a small circle around the pointer always shows the live,
    // un-warped, un-eaten screen, so whatever you aim at is really there and
    // clickable; it dissolves with the finale so the end state stays black
    float2 p = float2(uv.x * U.aspect, uv.y);
    float2 mp = float2(U.mouse.x * U.aspect, U.mouse.y);
    float bubble = (1.0 - smoothstep(0.055, 0.085, length(p - mp)))
                 * (1.0 - smoothstep(0.90, 0.98, U.progress));
    col = mix(col, live.sample(linBlack, uv).rgb, bubble);

    return float4(col, 1.0);
}
"""
