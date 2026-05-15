// HouseFire.metal — procedural fire (simplex noise + sparks + smoke).
//
// Port of Shadertoy "House fire" (view ID 7clSzX) to Metal Shading Language,
// with three local adjustments for the Sonata startup gate:
//   1. Color stops shifted to match the warm amber/orange/cream palette used
//      by the existing Canvas FlameAura blobs (StartupGate.swift).
//   2. Noise frequencies scaled by (640 / resolution.y) so the apparent flame
//      size stays consistent across window sizes (Shadertoy tuned for ~360px
//      tall output).
//   3. Night-sky background dropped — the SwiftUI gradient underneath provides
//      the dark base, so we output transparent pixels where there's no fire.
//
// Compiled at runtime by MetalFlameView from the bundled .metal source. SPM
// ships this file as a raw resource (no build-time metallib generation).

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms (mirrors `FlameUniforms` in MetalFlameView.swift)

struct Uniforms {
    float2 resolution;   // drawable pixels
    float2 mouse;        // pixels, y measured from the BOTTOM (Shadertoy convention)
    float  time;         // seconds since view creation
    float  _pad;
};

// MARK: - Tuning constants (matches the GLSL #defines)

constant float FIRE_SPEED      = 0.35;
constant float FIRE_HEIGHT     = 0.85;
constant float FIRE_INTENSITY  = 1.5;
constant float SPARK_SIZE      = 0.13;
constant float SMOKE_INTENSITY = 0.5;
constant float FIRE_WIDTH      = 1.0;

// Sonata-warm palette. See StartupGate.swift's blob colors (lines ~520-530)
// for the source aesthetic — outer is the ember orange, mid is the candle
// glow, core is the bright cream-white at the heart of a flame.
constant float3 COLOR_OUTER    = float3(0.95, 0.40, 0.12);
constant float3 COLOR_MID      = float3(1.00, 0.65, 0.20);
constant float3 COLOR_CORE     = float3(1.00, 0.92, 0.70);
constant float3 SMOKE_COLOR    = float3(1.00, 1.00, 1.00);
constant float3 SPARK_COLOR    = float3(1.00, 0.35, 0.05);

constant float SWIRL_STRENGTH  = 3.3;
constant float SWIRL_RADIUS    = 1.5;

// MARK: - Ashima Arts / Ian McEwan simplex noise (3D)

static inline float3 mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float4 mod289_4(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float4 permute(float4 x)  { return mod289_4(((x * 34.0) + 1.0) * x); }

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i  = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g  = step(x0.yzx, x0.xyz);
    float3 l  = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289_3(i);
    float4 p = permute(permute(permute(
                  i.z + float4(0.0, i1.z, i2.z, 1.0))
                + i.y + float4(0.0, i1.y, i2.y, 1.0))
                + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j  = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x  = x_ * ns.x + ns.yyyy;
    float4 y  = y_ * ns.x + ns.yyyy;
    float4 h  = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = rsqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

static float prng(float2 seed) {
    seed = fract(seed * float2(5.3983, 5.4427));
    seed += dot(seed.yx, seed.xy + float2(21.5351, 14.3137));
    return fract(seed.x * seed.y * 95.4337);
}

static float noiseStack(float3 pos, int octaves, float falloff) {
    float n = snoise(pos);
    float off = 1.0;
    if (octaves > 1) { pos *= 2.0; off *= falloff; n = (1.0 - off) * n + off * snoise(pos); }
    if (octaves > 2) { pos *= 2.0; off *= falloff; n = (1.0 - off) * n + off * snoise(pos); }
    if (octaves > 3) { pos *= 2.0; off *= falloff; n = (1.0 - off) * n + off * snoise(pos); }
    return (1.0 + n) / 2.0;
}

static float2 noiseStackUV(float3 pos, int octaves, float falloff) {
    float a = noiseStack(pos, octaves, falloff);
    float b = noiseStack(pos + float3(3984.293, 423.21, 5235.19), octaves, falloff);
    return float2(a, b);
}

static float hashDither(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// MARK: - Vertex (fullscreen triangle)

struct VOut { float4 pos [[position]]; };

vertex VOut fire_vs(uint vid [[vertex_id]]) {
    // Three vertices covering NDC (-1,-1)…(3,-1)…(-1,3), giving a triangle
    // that fully covers the viewport with no index buffer.
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// MARK: - Fragment

fragment float4 fire_fs(VOut in [[stage_in]],
                        constant Uniforms &u [[buffer(0)]]) {
    constexpr float PI = 3.14159265358979323846;

    // [[position]] is top-left origin in pixels. Shadertoy's fragCoord is
    // bottom-left, so we flip the y axis. The mouse uniform is already
    // bottom-origin (we convert on the Swift side), so it lines up.
    float2 fragCoord = float2(in.pos.x, u.resolution.y - in.pos.y);
    float2 res = u.resolution;
    float2 uv = fragCoord / res;
    float2 mouse = u.mouse / res;

    // ─── fire-region geometry (same as original) ──────────────────────
    float fireRegionWidth  = res.x * (0.15 + FIRE_WIDTH * 0.85);
    float fireRegionLeft   = (res.x - fireRegionWidth) * 0.5;
    float2 fireCoord       = float2(fragCoord.x - fireRegionLeft, fragCoord.y);
    float fireRegionHeight = res.y * FIRE_HEIGHT;
    float xpart            = fireCoord.x / fireRegionWidth;
    float ypart            = fireCoord.y / fireRegionHeight;
    float clipH            = fireRegionHeight * 0.7;
    float ypartClip        = fireCoord.y / clipH;
    float ypartClippedFalloff = clamp(2.0 - ypartClip, 0.0, 1.0);
    float ypartClipped     = min(ypartClip, 1.0);
    float ypartClippedn    = 1.0 - ypartClipped;
    float xfuel            = 1.0 - abs(2.0 * xpart - 1.0);

    float realTime = FIRE_SPEED * u.time;

    // Mouse offset + swirl. Note: when the mouse hasn't moved yet, Swift
    // sends (0,0) which lands in the corner and skews the flame heavily.
    // We dampen that by clamping the offset's contribution further down.
    float2 offset = (mouse - 0.5) * res * 0.05;

    // Resolution-scaled noise frequency. Shadertoy's defaults are tuned for
    // a ~360px tall canvas; at 1400×900 the noise reads too fine without
    // this. Larger window → smaller multiplier → coarser apparent noise.
    float noiseScale = 640.0 / max(res.y, 1.0);

    float2 coordScaled = (0.01 * fireCoord - 0.02 * float2(offset.x, 0.0)) * noiseScale;

    // Swirl: rotate the coordinate around the cursor with a Gaussian falloff
    // so dragging through the flame visibly stirs it.
    float2 mousePixel  = mouse * res;
    float2 toMouse     = fireCoord - mousePixel;
    float  swirlDist   = length(toMouse) / res.y;
    float  swirlFalloff = exp(-swirlDist * swirlDist * SWIRL_RADIUS);
    float  swirlAngle  = swirlFalloff * SWIRL_STRENGTH * 0.15;
    float  sc = sin(swirlAngle);
    float  cc = cos(swirlAngle);
    float2 swirlOffset = float2(toMouse.x * cc - toMouse.y * sc,
                                toMouse.x * sc + toMouse.y * cc) - toMouse;
    coordScaled += swirlOffset * 0.01 * noiseScale;

    float3 position = float3(coordScaled, 0.0) + float3(1223.0, 6434.0, 8425.0);
    float3 flow     = float3(4.1 * (0.5 - xpart) * pow(ypartClippedn, 4.0),
                             -2.0 * xfuel * pow(ypartClippedn, 64.0),
                             0.0);
    float3 timing   = realTime * float3(0.0, -1.7, 1.1) + flow;

    float3 displacePos = float3(1.0, 0.5, 1.0) * 2.4 * position + realTime * float3(0.01, -0.7, 1.3);
    float3 displace3   = float3(noiseStackUV(displacePos, 2, 0.4), 0.0);

    float3 noiseCoord  = float3(2.0, 1.0, 1.0) * position + timing + 0.4 * displace3;
    float  n           = noiseStack(noiseCoord, 3, 0.4);

    float  flames = pow(ypartClipped, 0.3 * xfuel) * pow(n, 0.3 * xfuel);
    float  f      = ypartClippedFalloff * pow(1.0 - flames * flames * flames, 8.0);

    float3 fireColor = mix(COLOR_OUTER, COLOR_MID, smoothstep(0.1, 0.5, f));
    fireColor        = mix(fireColor, COLOR_CORE, smoothstep(0.4, 0.9, f));
    float3 fire      = FIRE_INTENSITY * 1.5 * fireColor * f;

    // ─── smoke ────────────────────────────────────────────────────────
    float  smokeNoise  = 0.5 + snoise(0.4 * position + timing * float3(1.0, 1.0, 0.2)) / 2.0;
    float  smokeAmount = 0.3 * pow(max(xfuel, 0.0), 3.0) * pow(max(ypart, 0.0), 2.0)
                       * (smokeNoise + 0.4 * (1.0 - n));
    float3 smoke       = SMOKE_INTENSITY * SMOKE_COLOR * smokeAmount;

    // ─── sparks ───────────────────────────────────────────────────────
    float  sparkGridSize = 30.0;
    float2 sparkCoord    = fireCoord - float2(2.0 * offset.x, 190.0 * realTime);
    sparkCoord -= 30.0 * noiseStackUV(0.01 * float3(sparkCoord, 30.0 * u.time), 1, 0.4);
    sparkCoord += 100.0 * flow.xy;
    if (fmod(sparkCoord.y / sparkGridSize, 2.0) < 1.0) {
        sparkCoord.x += 0.5 * sparkGridSize;
    }
    float2 sparkGridIndex = floor(sparkCoord / sparkGridSize);
    float  sparkRandom    = prng(sparkGridIndex);
    float  sparkLife = min(10.0 * (1.0 - min((sparkGridIndex.y
                       + (190.0 * realTime / sparkGridSize))
                       / (24.0 - 20.0 * sparkRandom), 1.0)), 1.0);
    float3 sparks = float3(0.0);
    if (sparkLife > 0.0) {
        float  sparkSize     = xfuel * xfuel * sparkRandom * SPARK_SIZE;
        float  sparkRadians  = 999.0 * sparkRandom * 2.0 * PI + 2.0 * u.time;
        float2 sparkCircular = float2(sin(sparkRadians), cos(sparkRadians));
        float2 sparkOffset   = (0.5 - sparkSize) * sparkGridSize * sparkCircular;
        float2 sparkMod      = fmod(sparkCoord + sparkOffset, sparkGridSize)
                             - 0.5 * float2(sparkGridSize);
        float  sparkLength   = length(sparkMod);
        float  sparksGray    = max(0.0, 1.0 - sparkLength / max(sparkSize * sparkGridSize, 0.0001));
        sparks = sparkLife * sparksGray * SPARK_COLOR;
    }

    float inFireRegion = step(0.0, fireCoord.x)
                       * step(fireCoord.x, fireRegionWidth)
                       * step(0.0, fireCoord.y);
    float3 fireResult = (max(fire, sparks) + smoke) * inFireRegion;

    // Dropped: night-sky base color. The SwiftUI gradient under the MTKView
    // supplies the dark backdrop; pixels with no fire stay transparent so
    // the center vignette + wordmark composite cleanly on top.
    float3 color = fireResult;

    // 8-bit dither to break up the banding in the dim outer flame.
    float2 ditherSeed = fragCoord + fract(u.time) * 100.0;
    color += (hashDither(ditherSeed) - 0.5) / 255.0;
    color = clamp(color, 0.0, 1.0);

    // Premultiplied output: alpha tracks the brightest channel so the
    // SwiftUI background bleeds through the dim halo. Bright fire opaquely
    // covers the gradient; dim smoke at the top fades to background.
    float alpha = clamp(max(max(color.r, color.g), color.b), 0.0, 1.0);
    return float4(color, alpha);
}
